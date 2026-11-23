// city-experience — weather port.
// Ported from src/services/weatherService.ts: same condition mapping, same
// day/night + local-time handling, same mock fallback on failure. The
// OpenWeather API key moves server-side (VITE_OPENWEATHER_API_KEY in dev,
// OPENWEATHER_API_KEY in ECS task env) so it is no longer exposed in the
// browser bundle — a security talking point for the report.

import axios from 'axios';

const API_KEY = process.env.OPENWEATHER_API_KEY || process.env.VITE_OPENWEATHER_API_KEY || '';
const BASE_URL = 'https://api.openweathermap.org/data/2.5/weather';

// OpenWeatherMap weather condition mapping (verbatim from the FE service)
const conditionMapping: Record<string, string> = {
  Clear: 'Sunny',
  Clouds: 'Cloudy',
  Rain: 'Rain',
  Drizzle: 'Light rain',
  Thunderstorm: 'Thunderstorms',
  Snow: 'Snow',
  Mist: 'Fog',
  Smoke: 'Fog',
  Haze: 'Fog',
  Dust: 'Fog',
  Fog: 'Fog',
  Sand: 'Fog',
  Ash: 'Fog',
  Squall: 'Windy',
  Tornado: 'Stormy',
};

export interface WeatherData {
  city: string;
  country: string;
  latitude: number;
  longitude: number;
  temperature: number;
  condition: string;
  icon: string;
  humidity: number;
  windSpeed: number;
  localTime: string;
  isDay: boolean;
}

export async function getWeatherData(
  latitude: number,
  longitude: number,
  city: string,
  country: string
): Promise<WeatherData> {
  // No key configured (or a placeholder) → mock data, same as the FE did.
  if (!API_KEY || API_KEY === 'your-weather-api-key') {
    return getMockWeatherData(latitude, longitude, city, country);
  }

  try {
    const response = await axios.get(BASE_URL, {
      params: { lat: latitude, lon: longitude, appid: API_KEY, units: 'metric' },
      timeout: 10000,
    });

    const data = response.data;
    const temperature = Math.round(data.main.temp);
    const humidity = data.main.humidity;
    const windSpeed = Math.round(data.wind.speed * 3.6);
    const weatherMain = data.weather[0].main;
    const weatherDescription = data.weather[0].description;
    const weatherIcon = data.weather[0].icon;

    const condition = conditionMapping[weatherMain] || weatherMain;

    const currentTime = data.dt;
    const sunrise = data.sys.sunrise;
    const sunset = data.sys.sunset;
    const isDay = currentTime >= sunrise && currentTime <= sunset;

    const localTime = formatLocalTime(currentTime, data.timezone);

    return {
      city,
      country,
      latitude,
      longitude,
      temperature,
      condition,
      icon: `https://openweathermap.org/img/wn/${weatherIcon}@2x.png`,
      humidity,
      windSpeed,
      localTime,
      isDay,
    };
  } catch (error) {
    console.error('Error fetching weather data:', error);
    return getMockWeatherData(latitude, longitude, city, country);
  }
}

function formatLocalTime(unixTimestamp: number, timezoneOffset: number): string {
  try {
    const date = new Date(unixTimestamp * 1000);
    const localDate = new Date(date.getTime() + timezoneOffset * 1000);
    return localDate.toLocaleString('en-US', {
      hour: 'numeric',
      minute: 'numeric',
      hour12: true,
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      timeZone: 'UTC',
    });
  } catch {
    return new Date().toLocaleString('en-US', {
      hour: 'numeric',
      minute: 'numeric',
      hour12: true,
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  }
}

// Mock generator — verbatim behaviour from the FE service (realistic random
// weather per condition) so the app still works without the key.
export function getMockWeatherData(
  latitude: number,
  longitude: number,
  city: string,
  country: string
): WeatherData {
  const weatherConditions = [
    { condition: 'Sunny', tempRange: [18, 35] },
    { condition: 'Partly cloudy', tempRange: [12, 28] },
    { condition: 'Cloudy', tempRange: [8, 22] },
    { condition: 'Overcast', tempRange: [5, 18] },
    { condition: 'Fog', tempRange: [2, 15] },
    { condition: 'Light rain', tempRange: [8, 20] },
    { condition: 'Rain', tempRange: [5, 18] },
    { condition: 'Light snow', tempRange: [-8, 2] },
    { condition: 'Snow', tempRange: [-15, 0] },
  ];

  const selectedWeather = weatherConditions[Math.floor(Math.random() * weatherConditions.length)];

  const tempRange = selectedWeather.tempRange;
  const temperature = Math.floor(Math.random() * (tempRange[1] - tempRange[0] + 1)) + tempRange[0];

  let humidity: number;
  if (selectedWeather.condition.includes('Rain') || selectedWeather.condition === 'Fog') {
    humidity = Math.floor(Math.random() * 20) + 80;
  } else if (selectedWeather.condition.includes('Snow')) {
    humidity = Math.floor(Math.random() * 30) + 70;
  } else if (selectedWeather.condition === 'Sunny') {
    humidity = Math.floor(Math.random() * 40) + 30;
  } else {
    humidity = Math.floor(Math.random() * 50) + 40;
  }

  let windSpeed: number;
  if (selectedWeather.condition.includes('Storm') || selectedWeather.condition.includes('Thunder')) {
    windSpeed = Math.floor(Math.random() * 20) + 20;
  } else if (selectedWeather.condition.includes('Snow') && temperature < -5) {
    windSpeed = Math.floor(Math.random() * 15) + 10;
  } else if (selectedWeather.condition === 'Fog') {
    windSpeed = Math.floor(Math.random() * 8) + 2;
  } else {
    windSpeed = Math.floor(Math.random() * 20) + 5;
  }

  const isDay = Math.random() > 0.3;

  const now = new Date();
  const localTime = now.toLocaleString('en-US', {
    hour: 'numeric',
    minute: 'numeric',
    hour12: true,
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  });

  return {
    city,
    country,
    latitude,
    longitude,
    temperature,
    condition: selectedWeather.condition,
    icon: `/icons/${selectedWeather.condition.toLowerCase().replace(/ /g, '-')}.png`,
    humidity,
    windSpeed,
    localTime,
    isDay,
  };
}