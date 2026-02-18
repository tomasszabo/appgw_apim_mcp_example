using System;

namespace MCPWeatherServer.Models
{
    public class WeatherData
    {
    public string Location { get; set; }
    public double Temperature { get; set; }
    public int Humidity { get; set; }
    public string Condition { get; set; }
    public DateTime Timestamp { get; set; }
    }
}