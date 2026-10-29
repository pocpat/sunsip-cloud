import axios from 'axios';
import type { WeatherData } from '../store/appStore';
import { addBreadcrumb } from '../lib/sentry';

// Weather now comes from the city-experience microservice (Microservice 1).
// Same behaviour as the old browser-side implementation — same shape, same
// mock fallback — but the OpenWeather key and the call happen server-side.

const CITY_API_BASE = import.meta.env.VITE_CITY_API_BASE || '/api/city';

export async function getWeatherData(
  latitude: number,
  longitude: number,
  city: string,
  country: string
): Promise<WeatherData> {
  try {
    addBreadcrumb(`Fetching weather for ${city}, ${country} from city-experience`, 'weather');
    const response = await axios.get(`${CITY_API_BASE}/weather`, {
      params: { lat: latitude, lon: longitude, city, country },
      timeout: 15000,
    });
    return response.data.weather as WeatherData;
  } catch (error) {
    console.error('Error fetching weather data from city-experience:', error);
    addBreadcrumb(`Weather service failed, using mock weather for ${city}, ${country}`, 'weather');
    return getMockWeatherData(latitude, longitude, city, country);
  }
}

// Kept for portfolio/demo mode and as the offline fallback: realistic random
// weather, same ranges as before.
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