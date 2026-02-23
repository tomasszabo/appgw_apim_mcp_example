using ModelContextProtocol.Server;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Identity.Web;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using MCPWeatherServer.Services;
using MCPWeatherServer.Models;
using MCPWeatherServer.Tools;

// Helper method to build scopes_supported list from role and scope configuration
static string[] GetScopesSupported(string requiredRole, string requiredScope)
{
    var scopes = new List<string>();
    if (!string.IsNullOrEmpty(requiredRole)) scopes.Add(requiredRole);
    if (!string.IsNullOrEmpty(requiredScope)) scopes.Add(requiredScope);
    return scopes.Count > 0 ? scopes.Distinct().ToArray() : new[] { "openid", "profile", "email" };
}

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
var audiences = builder.Configuration.GetSection("AzureAd:Audience").Get<string[]>() ?? Array.Empty<string>();
var primaryAudience = audiences.Length > 0 ? audiences[0] : string.Empty; // First audience for metadata
var requiredRole = builder.Configuration["AzureAd:RequiredRole"];
var requiredScope = builder.Configuration["AzureAd:RequiredScope"];
var enableAuth = builder.Configuration.GetValue<bool>("AzureAd:EnableAuth", false);

if (enableAuth)
{
    builder.Services
        .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(options =>
        {
            // Don't bind Audience - we handle it manually below as an array
            // Configure token validation to accept multiple audiences
            options.TokenValidationParameters.ValidateAudience = true;
            options.TokenValidationParameters.ValidateIssuer = true;
            
            // Accept both v1.0 and v2.0 issuer formats
            if (!string.IsNullOrEmpty(tenantId))
            {
                options.TokenValidationParameters.ValidIssuers = new[]
                {
                    $"https://sts.windows.net/{tenantId}/",  // v1.0 endpoint
                    $"https://login.microsoftonline.com/{tenantId}/v2.0"  // v2.0 endpoint
                };
            }
            
            if (audiences.Length > 0)
            {
                var validAudiences = new List<string>();
                
                foreach (var aud in audiences)
                {
                    validAudiences.Add(aud);
                    // Also add version without api:// prefix if present
                    if (aud.StartsWith("api://"))
                    {
                        validAudiences.Add(aud.Replace("api://", ""));
                    }
                }
                
                options.TokenValidationParameters.ValidAudiences = validAudiences.ToArray();
            }
            
            // Add JWT bearer events for debugging and better error handling
            options.Events = new JwtBearerEvents
            {
                OnAuthenticationFailed = context =>
                {
                    var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
                    logger.LogError(context.Exception, "JWT authentication failed: {Message}", context.Exception.Message);
                    return Task.CompletedTask;
                },
                OnTokenValidated = context =>
                {
                    var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
                    var claims = context.Principal?.Claims.Select(c => $"{c.Type}={c.Value}");
                    logger.LogInformation("JWT token validated successfully. Claims: {Claims}", string.Join(", ", claims ?? Array.Empty<string>()));
                    return Task.CompletedTask;
                },
                OnChallenge = context =>
                {
                    var logger = context.HttpContext.RequestServices.GetRequiredService<ILogger<Program>>();
                    logger.LogWarning("JWT authentication challenge: {Error} - {ErrorDescription}", context.Error, context.ErrorDescription);
                    return Task.CompletedTask;
                }
            };
        },
        options =>
        {
            // Bind Instance, TenantId, ClientId, etc - but Audience will be ignored since it's an array
            options.Instance = builder.Configuration["AzureAd:Instance"];
            options.TenantId = builder.Configuration["AzureAd:TenantId"];
            options.ClientId = builder.Configuration["AzureAd:ClientId"];
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

// OpenID Connect Discovery endpoint - redirect to Azure AD's OIDC configuration
// This is what Copilot Studio and other OAuth/OIDC clients will query first
app.MapGet("/.well-known/openid-configuration", () =>
{
    if (string.IsNullOrEmpty(tenantId) || tenantId == "common" || tenantId == "YOUR_API_APP_ID_HERE")
    {
        // Auth not configured - return minimal metadata
        var metadata = new
        {
            mcp_server_version = "1.0.0",
            auth_enabled = false,
            message = "OpenID Connect authentication is not configured on this server",
            warning = tenantId == "common" 
                ? "TenantId 'common' detected - this will NOT work with Copilot Studio. Use your actual tenant ID."
                : null
        };
        return Results.Ok(metadata);
    }

    // Redirect to Azure AD's OpenID Connect configuration endpoint
    var oidcConfigUrl = $"https://login.microsoftonline.com/{tenantId}/v2.0/.well-known/openid-configuration";
    return Results.Redirect(oidcConfigUrl, permanent: false);
});

// Health check endpoint
app.MapGet("/health", () =>
    Results.Ok(new { status = "healthy", timestamp = DateTime.UtcNow }));

// ===== REST API Endpoints for Weather Data =====

// GET /api/weather/{location} - Get current weather for a location
app.MapGet("/api/weather/{location}", async (string location, WeatherService weatherService, AuthorizationService authService) =>
{
    try
    {
        authService.RequireAuthorization();
        var request = new WeatherRequest { Location = location, Date = DateTime.UtcNow };
        var weather = await weatherService.GetWeatherDataAsync(request);
        return Results.Ok(weather);
    }
    catch (UnauthorizedAccessException ex)
    {
        return Results.Unauthorized();
    }
    catch (ArgumentException ex)
    {
        return Results.BadRequest(new { error = ex.Message });
    }
});

app.Run();