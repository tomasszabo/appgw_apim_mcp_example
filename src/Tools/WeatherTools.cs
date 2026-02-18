using System;
using System.ComponentModel;
using System.Threading.Tasks;
using ModelContextProtocol.Server;
using MCPWeatherServer.Models;
using MCPWeatherServer.Services;

namespace MCPWeatherServer.Tools
{
    /// <summary>
    /// Weather tools exposed via MCP server
    /// Automatically discovered and registered by the MCP SDK
    /// Protected with OAuth2 authorization
    /// </summary>
    [McpServerToolType]
    public class WeatherTools
    {
        private readonly WeatherService _weatherService;
        private readonly AuthorizationService _authorizationService;

        public WeatherTools(WeatherService weatherService, AuthorizationService authorizationService)
        {
            _weatherService = weatherService ?? throw new ArgumentNullException(nameof(weatherService));
            _authorizationService = authorizationService ?? throw new ArgumentNullException(nameof(authorizationService));
        }

        /// <summary>
        /// Get weather for a location (OAuth2 protected)
        /// </summary>
        [McpServerTool]
        [Description("Get current and historical weather information for a specific location. Returns temperature, humidity, condition, and timestamp. Requires mcp.access scope.")]
        public async Task<string> GetWeather(
            [Description("City name or location (e.g., 'New York', 'London')")] string location,
            [Description("Optional date in YYYY-MM-DD format. If omitted, uses current date.")] string date = null)
        {
            // Verify authorization
            _authorizationService.RequireAuthorization();

            if (string.IsNullOrEmpty(location))
            {
                throw new ArgumentException("location parameter is required");
            }

            var dateObj = string.IsNullOrEmpty(date) ? DateTime.Now : DateTime.Parse(date);

            var request = new WeatherRequest
            {
                Location = location,
                Date = dateObj
            };

            try
            {
                var result = await _weatherService.GetWeatherDataAsync(request);
                return $"Weather for {result.Location}: {result.Temperature}°F, {result.Condition}, {result.Humidity}% humidity (as of {result.Timestamp:O})";
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"Error fetching weather for {location}: {ex.Message}", ex);
            }
        }
    }
}
