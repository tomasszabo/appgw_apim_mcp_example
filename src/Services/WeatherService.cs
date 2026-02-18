using System;
using System.Threading.Tasks;
using MCPWeatherServer.Models;

namespace MCPWeatherServer.Services
{
    /// <summary>
    /// Service for fetching weather data
    /// </summary>
    public class WeatherService
    {
        private readonly Random _random = new Random();

        public async Task<WeatherData> GetWeatherDataAsync(WeatherRequest request)
        {
            // Validate request
            if (request == null || string.IsNullOrEmpty(request.Location))
            {
                throw new ArgumentException("Invalid weather request: Location is required.");
            }

            // Simulate async weather fetch
            await Task.Delay(100);

            return new WeatherData
            {
                Location = request.Location,
                Temperature = Math.Round(_random.Next(50, 950) / 10.0, 1),
                Humidity = _random.Next(30, 90),
                Condition = new[] { "Sunny", "Cloudy", "Rainy", "Partly Cloudy", "Snowy" }[_random.Next(5)],
                Timestamp = DateTime.UtcNow
            };
        }
    }
}