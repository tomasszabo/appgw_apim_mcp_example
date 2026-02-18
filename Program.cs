using ModelContextProtocol.Server;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Identity.Web;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using System;
using MCPWeatherServer.Services;
using MCPWeatherServer.Tools;

var builder = WebApplication.CreateBuilder(args);

// Add core services
builder.Services.AddSingleton<WeatherService>();
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<AuthorizationService>();

// Configure CORS for MCP clients
builder.Services.AddCors(options =>
{
    options.AddPolicy("MCPPolicy", policy =>
    {
        policy.AllowAnyOrigin()
              .AllowAnyMethod()
              .AllowAnyHeader()
              .WithExposedHeaders("Content-Type", "Authorization");
    });
});

// Configure Azure AD / OAuth2 authentication if enabled
var azureAd = builder.Configuration.GetSection("AzureAd");
var tenantId = builder.Configuration["AzureAd:TenantId"];
var audience = builder.Configuration["AzureAd:Audience"];
var requiredScope = builder.Configuration["AzureAd:RequiredScope"];
var enableAuth = builder.Configuration.GetValue<bool>("AzureAd:EnableAuth", false);

if (enableAuth)
{
    builder.Services
        .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(options =>
        {
            builder.Configuration.Bind("AzureAd", options);
            
            // Configure token validation to accept both api://appId and just appId as valid audiences
            options.TokenValidationParameters.ValidateAudience = true;
            var configuredAudience = builder.Configuration["AzureAd:Audience"];
            if (!string.IsNullOrEmpty(configuredAudience))
            {
                // Extract app ID from api://appId format
                var appId = configuredAudience.Replace("api://", "");
                // Accept both formats
                options.TokenValidationParameters.ValidAudiences = new[] { configuredAudience, appId };
            }
        },
        options =>
        {
            builder.Configuration.Bind("AzureAd", options);
        });

    builder.Services.AddAuthorizationBuilder()
        .AddPolicy("McpAccess", policy =>
        {
            policy.RequireAuthenticatedUser();
            var requiredScope = azureAd["RequiredScope"];
            if (!string.IsNullOrEmpty(requiredScope))
            {
                policy.RequireClaim("scp", requiredScope);
            }
        });
}

// Add MCP Server with auto-discovery of tools from assembly
builder.Services.AddMcpServer()
    .WithHttpTransport()
    .WithToolsFromAssembly();

var app = builder.Build();

// Enable CORS
app.UseCors("MCPPolicy");

// Add authentication/authorization middleware if enabled
if (enableAuth)
{
    app.UseAuthentication();
    app.UseAuthorization();
}

// Map MCP server endpoints
app.MapMcp();

// OAuth 2.0 Authorization Server Metadata endpoint (RFC 8414)
// REQUIRED FIELDS for Copilot Studio: issuer, authorization_endpoint, token_endpoint,
// grant_types_supported, token_endpoint_auth_methods_supported, code_challenge_methods_supported
app.MapGet("/.well-known/oauth-authorization-server", () =>
{
    // Return metadata even when auth is disabled - clients need this for discovery
    if (string.IsNullOrEmpty(tenantId) || tenantId == "common" || tenantId == "YOUR_API_APP_ID_HERE")
    {
        // Auth not configured - return minimal metadata indicating no OAuth support
        // WARNING: TenantId "common" will NOT work with Copilot Studio token acquisition!
        // You MUST use your actual tenant ID for Copilot Studio integration.
        var metadata = new
        {
            mcp_server_version = "1.0.0",
            mcp_oauth_mode = "disabled",
            auth_enabled = false,
            message = "OAuth authentication is not configured on this server",
            warning = tenantId == "common" 
                ? "TenantId 'common' detected - this will NOT work with Copilot Studio. Use your actual tenant ID."
                : null
        };
        return Results.Ok(metadata);
    }

    var authorizationEndpoint = $"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/authorize";
    var tokenEndpoint = $"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token";
    var issuer = $"https://login.microsoftonline.com/{tenantId}/v2.0";
    
    // All required fields per Copilot Studio requirements + additional Microsoft Entra fields
    var fullMetadata = new
    {
        // === REQUIRED by Copilot Studio ===
        issuer = issuer,
        authorization_endpoint = authorizationEndpoint,
        token_endpoint = tokenEndpoint,
        grant_types_supported = new[] { "authorization_code", "implicit", "client_credentials" },
        token_endpoint_auth_methods_supported = new[] { "client_secret_post", "client_secret_basic", "private_key_jwt" },
        code_challenge_methods_supported = new[] { "plain", "S256" },
        
        // === Additional Microsoft Entra / OpenID Connect fields ===
        jwks_uri = $"https://login.microsoftonline.com/{tenantId}/discovery/v2.0/keys",
        response_types_supported = new[] { "code", "token", "id_token", "code id_token", "id_token token" },
        response_modes_supported = new[] { "query", "fragment", "form_post" },
        subject_types_supported = new[] { "pairwise" },
        scopes_supported = !string.IsNullOrEmpty(requiredScope) 
            ? new[] { "openid", "profile", "email", requiredScope }
            : new[] { "openid", "profile", "email" },
        claims_supported = new[] { "sub", "iss", "aud", "exp", "iat", "auth_time", "acr", "nonce", "preferred_username", "name", "tid", "ver", "at_hash", "c_hash", "email" },
        
        // === MCP-specific fields ===
        audience = audience,
        mcp_server_version = "1.0.0",
        mcp_oauth_mode = enableAuth ? "enabled" : "configured_but_disabled",
        auth_enabled = enableAuth
    };

    return Results.Ok(fullMetadata);
});

// OAuth 2.0 Protected Resource Metadata endpoint (RFC 9728) - MANDATORY for MCP
// REQUIRED FIELDS for Copilot Studio: resource, authorization_servers
app.MapGet("/.well-known/oauth-protected-resource", (IConfiguration config, HttpContext context) =>
{
    // Use configured public URL (for App Gateway/APIM scenarios) or derive from request
    // CRITICAL: This must exactly match the MCP base URL configured in Copilot Studio
    var publicUrl = config["PublicMcpBaseUrl"];
    var baseUrl = !string.IsNullOrEmpty(publicUrl) && !publicUrl.Contains("YOUR_")
        ? publicUrl.TrimEnd('/')
        : $"{context.Request.Scheme}://{context.Request.Host}{context.Request.PathBase}".TrimEnd('/');
    
    // Return metadata even when auth is disabled - clients need this for discovery
    if (string.IsNullOrEmpty(tenantId) || tenantId == "common" || tenantId == "YOUR_API_APP_ID_HERE")
    {
        // Auth not configured - return minimal required fields
        var metadata = new
        {
            // === REQUIRED by Copilot Studio ===
            resource = baseUrl,  // CRITICAL: Must exactly match MCP base URL - no trailing slash mismatch allowed
            authorization_servers = new string[] { },  // Empty when auth not configured
            
            // === MCP-specific fields ===
            mcp_server_version = "1.0.0",
            auth_enabled = false
        };
        return Results.Ok(metadata);
    }

    var authorizationEndpoint = $"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/authorize";
    var tokenEndpoint = $"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token";
    var issuer = $"https://login.microsoftonline.com/{tenantId}/v2.0";
    
    // All required fields per Copilot Studio requirements + additional RFC 9728 fields
    var fullMetadata = new
    {
        // === REQUIRED by Copilot Studio ===
        resource = baseUrl,  // CRITICAL: Must exactly match MCP base URL - no trailing slash mismatch allowed
        authorization_servers = new[] { issuer },
        
        // === Additional RFC 9728 / Microsoft Entra fields ===
        bearer_methods_supported = new[] { "header" },
        resource_signing_alg_values_supported = new[] { "RS256" },
        authorization_endpoint = authorizationEndpoint,
        token_endpoint = tokenEndpoint,
        issuer = issuer,
        scopes_supported = !string.IsNullOrEmpty(requiredScope) 
            ? new[] { requiredScope }
            : new string[] { },
        
        // === MCP-specific fields ===
        mcp_server_version = "1.0.0",
        auth_enabled = enableAuth
    };

    return Results.Ok(fullMetadata);
});

// Health check endpoint
app.MapGet("/health", () =>
    Results.Ok(new { status = "healthy", timestamp = DateTime.UtcNow }));

app.Run();