using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Claims;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace MCPWeatherServer.Services
{
    /// <summary>
    /// Service for checking authorization and claims in MCP requests
    /// </summary>
    public class AuthorizationService
    {
        private readonly IHttpContextAccessor _httpContextAccessor;
        private readonly IConfiguration _configuration;
        private readonly ILogger<AuthorizationService> _logger;

        public AuthorizationService(IHttpContextAccessor httpContextAccessor, IConfiguration configuration, ILogger<AuthorizationService> logger)
        {
            _httpContextAccessor = httpContextAccessor;
            _configuration = configuration;
            _logger = logger;
        }

        /// <summary>
        /// Check if the current request has a valid JWT token
        /// </summary>
        public bool IsAuthenticated()
        {
            var httpContext = _httpContextAccessor.HttpContext;
            if (httpContext == null)
            {
                _logger.LogWarning("HttpContext is null - cannot check authentication");
                return false;
            }

            var user = httpContext.User;
            if (user == null)
            {
                _logger.LogWarning("User principal is null");
                return false;
            }

            var isAuthenticated = user.Identity?.IsAuthenticated ?? false;
            
            if (!isAuthenticated)
            {
                var authHeader = httpContext.Request.Headers["Authorization"].FirstOrDefault();
                _logger.LogWarning("User is not authenticated. Authorization header present: {HasAuthHeader}, Identity type: {IdentityType}", 
                    !string.IsNullOrEmpty(authHeader), 
                    user.Identity?.GetType().Name ?? "null");
            }
            else
            {
                var claims = user.Claims.Select(c => $"{c.Type}={c.Value}");
                _logger.LogDebug("User authenticated with claims: {Claims}", string.Join(", ", claims));
            }

            return isAuthenticated;
        }

        /// <summary>
        /// Check if the current request has the required MCP role OR scope
        /// </summary>
        public bool HasRequiredRole()
        {
            var requiredRole = _configuration["AzureAd:RequiredRole"];
            var requiredScope = _configuration["AzureAd:RequiredScope"];
            
            _logger.LogDebug("HasRequiredRole check: RequiredRole={RequiredRole}, RequiredScope={RequiredScope}", 
                requiredRole ?? "null", requiredScope ?? "null");
            
            // If neither role nor scope is configured, allow access
            if (string.IsNullOrEmpty(requiredRole) && string.IsNullOrEmpty(requiredScope))
            {
                _logger.LogDebug("No required role or scope configured - allowing access");
                return true;
            }

            var user = _httpContextAccessor.HttpContext?.User;
            if (user == null)
            {
                _logger.LogWarning("User principal is null in HasRequiredRole");
                return false;
            }

            // If using Copilot Studio default audience (00000002-0000-0000-c000-000000000000),
            // tokens don't contain roles/scopes - allow access automatically
            var audienceClaim = user.FindFirst("aud")?.Value;
            _logger.LogDebug("Audience claim: {AudienceClaim}", audienceClaim ?? "null");
            
            if (audienceClaim == "00000002-0000-0000-c000-000000000000")
            {
                _logger.LogDebug("Using Copilot Studio audience - allowing access");
                return true;
            }

            // Check roles claim if role is configured
            // Note: Azure AD uses "roles" in the token, but Microsoft.Identity.Web may map it to
            // "http://schemas.microsoft.com/ws/2008/06/identity/claims/role" or other variants
            if (!string.IsNullOrEmpty(requiredRole))
            {
                // Check multiple possible claim types for roles
                var rolesClaim = user.FindAll("roles")
                    .Concat(user.FindAll(ClaimTypes.Role))
                    .Concat(user.FindAll("http://schemas.microsoft.com/identity/claims/role"))
                    .Concat(user.FindAll("role"));
                    
                var roles = rolesClaim.Select(r => r.Value).ToList();
                _logger.LogDebug("Checking for required role '{RequiredRole}'. Found roles: {Roles}", 
                    requiredRole, string.Join(", ", roles));
                
                foreach (var role in rolesClaim)
                {
                    if (role.Value.Contains(requiredRole, StringComparison.OrdinalIgnoreCase))
                    {
                        _logger.LogDebug("Required role found: {Role}", requiredRole);
                        return true;
                    }
                }
            }

            // Check scope claim if scope is configured (scopes can be space-separated in a single claim)
            // Note: Azure AD uses "scp" in the token, but Microsoft.Identity.Web may map it to
            // "http://schemas.microsoft.com/identity/claims/scope" or "scope"
            if (!string.IsNullOrEmpty(requiredScope))
            {
                // Check multiple possible claim types for scopes
                var scopesClaim = user.FindAll("scp")
                    .Concat(user.FindAll("http://schemas.microsoft.com/identity/claims/scope"))
                    .Concat(user.FindAll("scope"));
                    
                var scopes = scopesClaim.SelectMany(s => s.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries)).ToList();
                _logger.LogDebug("Checking for required scope '{RequiredScope}'. Found scopes: {Scopes}", 
                    requiredScope, string.Join(", ", scopes));
                
                foreach (var scope in scopesClaim)
                {
                    var scopeValues = scope.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    if (scopeValues.Any(s => s.Equals(requiredScope, StringComparison.OrdinalIgnoreCase)))
                    {
                        _logger.LogDebug("Required scope found: {Scope}", requiredScope);
                        return true;
                    }
                }
            }

            _logger.LogWarning("No required role or scope found in token claims");
            return false;
        }

        /// <summary>
        /// Check if authorization is enabled via configuration
        /// </summary>
        public bool IsAuthorizationEnabled()
        {
            return _configuration.GetValue<bool>("AzureAd:EnableAuth", false);
        }

        /// <summary>
        /// Verify authorization and throw if not authorized
        /// </summary>
        public void RequireAuthorization()
        {
            if (!IsAuthorizationEnabled())
            {
                _logger.LogDebug("Authorization is disabled - allowing access");
                return; // Authorization not enabled, allow access
            }

            _logger.LogDebug("Authorization is enabled - checking authentication and permissions");

            if (!IsAuthenticated())
            {
                _logger.LogError("Authentication check failed - user is not authenticated");
                throw new UnauthorizedAccessException("Authentication required. Please provide a valid JWT token.");
            }

            if (!HasRequiredRole())
            {
                var requiredRole = _configuration["AzureAd:RequiredRole"];
                var requiredScope = _configuration["AzureAd:RequiredScope"];
                var requirements = new List<string>();
                if (!string.IsNullOrEmpty(requiredRole)) requirements.Add($"role: {requiredRole}");
                if (!string.IsNullOrEmpty(requiredScope)) requirements.Add($"scope: {requiredScope}");
                var message = requirements.Any() 
                    ? $"Insufficient permissions. Required: {string.Join(" OR ", requirements)}"
                    : "Insufficient permissions";
                
                _logger.LogError("Authorization check failed: {Message}", message);
                throw new UnauthorizedAccessException(message);
            }

            _logger.LogDebug("Authorization check passed");
        }

        /// <summary>
        /// Get the principal/user info from the current request
        /// </summary>
        public ClaimsPrincipal GetPrincipal()
        {
            return _httpContextAccessor.HttpContext?.User;
        }

        /// <summary>
        /// Get a specific claim value from the current request
        /// </summary>
        public string GetClaimValue(string claimType)
        {
            return _httpContextAccessor.HttpContext?.User.FindFirst(claimType)?.Value;
        }
    }
}