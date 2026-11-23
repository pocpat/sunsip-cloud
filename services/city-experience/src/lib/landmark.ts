// city-experience — landmark enrichment port (from api/generate-landmark.js).
// OpenRouter free text model returns a short landmark phrase per city for the
// image prompt; in-memory cache keeps repeat cities free; graceful null.

import axios from 'axios';

const cache = new Map<string, string>();

const OPENROUTER_API_KEY = process.env.VITE_OPENROUTER_API_KEY || process.env.OPENROUTER_API_KEY;
const OPENROUTER_TEXT_MODEL =
  process.env.VITE_OPENROUTER_TEXT_MODEL || 'inclusionai/ling-3.0-flash-sante:free';
const OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1/chat/completions';

export async function getLandmark(city: string, country: string): Promise<string | null> {
  const cacheKey = `${city.toLowerCase()}-${country.toLowerCase()}`;

  if (cache.has(cacheKey)) {
    console.log(`Serving "${cacheKey}" landmark from CACHE`);
    return cache.get(cacheKey) ?? null;
  }

  if (!OPENROUTER_API_KEY || OPENROUTER_API_KEY === 'test-openrouter-key') {
    return null;
  }

  const prompt = `Your task is to create a short, visual phrase for an image generation prompt about the city: "${city}, ${country}". Name ONE famous, visually distinctive landmark or iconic feature of that city. Answer with the landmark phrase ONLY, at most 5 words, no punctuation, no explanation.`;

  try {
    const response = await axios.post(
      OPENROUTER_BASE_URL,
      {
        model: OPENROUTER_TEXT_MODEL,
        messages: [{ role: 'user', content: prompt }],
        max_tokens: 300,
        temperature: 0.3,
      },
      {
        headers: {
          Authorization: `Bearer ${OPENROUTER_API_KEY}`,
          'Content-Type': 'application/json',
        },
        timeout: 20000,
      }
    );

    const rawContent = response.data?.choices?.[0]?.message?.content;
    let landmark: string | null = null;
    if (typeof rawContent === 'string' && rawContent.trim()) {
      landmark =
        rawContent
          .replace(/<\/think>/g, '')
          .replace(/<think>[\s\S]*?<\/think>/g, '')
          .trim()
          .split('\n')[0]
          .slice(0, 60) || null;
    }

    if (landmark) {
      cache.set(cacheKey, landmark);
    }
    return landmark;
  } catch (error: any) {
    console.error(
      `Error calling OpenRouter for "${cacheKey}":`,
      error?.response?.data || error?.message
    );
    return null;
  }
}