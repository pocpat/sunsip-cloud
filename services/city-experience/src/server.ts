// city-experience — SunSip Microservice 1 on Express (weather, mood-matched
// cocktail, AI city image, landmark enrichment). Ported from the frontend
// services (weatherService, cocktailService) and the Netlify functions
// (generate-image, generate-landmark). Stateles — no database here; saved
// receipts live in the user-collection service (Microservice 2). In
// production this runs on ECS Fargate behind its own public ALB.
//
// Routes:
//   GET  /api/city/weather?lat=&lon=&city=&country=   — weather for the city
//   POST /api/city/cocktail-match                     — mood-matched cocktail
//   POST /api/city/generate-image                     — AI image (3-provider chain)
//   POST /api/city/landmark                           — landmark phrase (OpenRouter)
//   GET  /healthz

import express from 'express';
import cors from 'cors';
import { getWeatherData } from './lib/weather.js';
import { getCocktailSuggestion } from './lib/cocktail.js';
import { generateImage } from './lib/imagegen.js';
import { getLandmark } from './lib/landmark.js';

const PORT = Number(process.env.PORT || 4001);
const app = express();
app.use(cors({ origin: true, credentials: true }));
app.use(express.json());

app.get('/api/city/weather', async (req, res) => {
  try {
    const { lat, lon, city, country } = req.query;
    if (lat === undefined || lon === undefined || !city || !country) {
      return res.status(400).json({ error: 'lat, lon, city and country are required.' });
    }
    const weather = await getWeatherData(
      Number(lat),
      Number(lon),
      String(city),
      String(country)
    );
    return res.status(200).json({ weather });
  } catch (error) {
    console.error('Weather error:', error);
    return res.status(500).json({ error: 'Failed to fetch weather data.' });
  }
});

app.post('/api/city/cocktail-match', async (req, res) => {
  try {
    const { countryCode, weatherCondition, temperature } = req.body || {};
    if (!countryCode || !weatherCondition || typeof temperature !== 'number') {
      return res.status(400).json({
        error: 'countryCode, weatherCondition and temperature (number) are required.',
      });
    }
    const cocktail = await getCocktailSuggestion(
      String(countryCode),
      String(weatherCondition),
      Number(temperature)
    );
    return res.status(200).json({ cocktail });
  } catch (error) {
    console.error('Cocktail-match error:', error);
    return res.status(500).json({ error: 'Failed to match a cocktail.' });
  }
});

app.post('/api/city/generate-image', async (req, res) => {
  try {
    const prompt = String(req.body?.prompt ?? '')
      .trim()
      .slice(0, 900);
    if (!prompt) {
      return res.status(400).json({ error: 'prompt is required' });
    }

    const result = await generateImage(prompt);

    if (!result) {
      console.error('generate-image: all providers failed');
      return res
        .status(502)
        .json({ imageUrl: null, provider: null, error: 'all providers failed' });
    }

    console.log(`generate-image: served by ${result.provider}`);
    return res.status(200).json({ imageUrl: result.url, provider: result.provider });
  } catch (error) {
    console.error('Generate-image error:', error);
    return res.status(500).json({ imageUrl: null, error: 'Image generation failed.' });
  }
});

app.post('/api/city/landmark', async (req, res) => {
  try {
    const { city, country } = req.body || {};
    if (!city || !country) {
      return res.status(400).json({ error: 'City and country are required.' });
    }
    const landmark = await getLandmark(String(city), String(country));
    return res.status(200).json({ landmark });
  } catch (error) {
    console.error('Landmark error:', error);
    return res.status(500).json({ landmark: null, error: 'Failed to contact the AI service.' });
  }
});

app.get('/healthz', (_req, res) => {
  return res.status(200).json({ ok: true, service: 'city-experience' });
});

app.listen(PORT, () => {
  console.log(`city-experience service listening on http://localhost:${PORT}`);
});