using System;
using System.Security.Claims;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;

namespace MCPWeatherServer.Services
{
    /// <summary>
    /// Service for checking authorization and claims in MCP requests
    /// </summary>
    public class AuthorizationService
    {
        private readonly IHttpContextAccessor _httpContextAccessor;
        private readonly IConfiguration _configuration;

        public AuthorizationService(IHttpContextAccessor httpContextAccessor, IConfiguration configuration)
        {
            _httpContextAccessor = httpContextAccessor;
            _configuration = configuration;
        }

        /// <summary>
        /// Check if the current request has a valid JWT token
        /// </summary>
        public bool IsAuthenticated()
        {
            var user = _httpContextAccessor.HttpContext?.User;
            return user?.Identity?.IsAuthenticated ?? false;
        }

        /// <summary>
        /// Check if the current request has the required MCP scope
        /// </summary>
        public bool HasRequiredScope()
        {
            var requiredScope = _configuration["AzureAd:RequiredScope"];
            if (string.IsNullOrEmpty(requiredScope))
            {
                return true; // No scope required
            }

            var scopeClaim = _httpContextAccessor.HttpContext?.User.FindFirst("scp");
            if (scopeClaim?.Value == requiredScope)
            {
                return true;
            }

            // Also check roles claim
            var roleClaim = _httpContextAccessor.HttpContext?.User.FindFirst("roles");
            return roleClaim?.Value == requiredScope;
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
                return; // Authorization not enabled, allow access
            }

            if (!IsAuthenticated())
            {
                throw new UnauthorizedAccessException("Authentication required. Please provide a valid JWT token.");
            }

            if (!HasRequiredScope())
            {
                var requiredScope = _configuration["AzureAd:RequiredScope"];
                throw new UnauthorizedAccessException($"Insufficient permissions. Required scope: {requiredScope}");
            }
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
