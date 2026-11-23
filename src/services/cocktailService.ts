import axios from 'axios';
import type { CocktailData } from '../store/appStore';
import { addBreadcrumb } from '../lib/sentry';

// Cocktail matching now happens in the city-experience microservice
// (Microservice 1): country → spirit preferences, weather → mood map and the
// TheCocktailDB search all run server-side. This client keeps the same
// exported signature the UI already uses, with the same hardcoded fallbacks
// for portfolio/demo mode.

const CITY_API_BASE = import.meta.env.VITE_CITY_API_BASE || '/api/city';

const fallbackCocktails: CocktailData[] = [
  {
    name: 'Classic Old Fashioned',
    description: 'A timeless cocktail that showcases the rich flavors of bourbon or rye whiskey.',
    ingredients: [
      '2 oz bourbon or rye whiskey',
      '1 sugar cube',
      '2-3 dashes Angostura bitters',
      'Orange peel for garnish',
    ],
    recipe: [
      'Place sugar cube in an old-fashioned glass',
      'Add bitters and a splash of water',
      'Muddle until sugar is dissolved',
      'Add bourbon or rye whiskey',
      'Add ice (preferably one large cube)',
      'Stir gently',
      'Express orange peel over the drink and drop it in',
    ],
    imageUrl: 'https://images.pexels.com/photos/5379228/pexels-photo-5379228.jpeg',
    mood: 'cozy',
  },
  {
    name: 'Gin Fizz',
    description: 'A refreshing, effervescent cocktail perfect for warm days.',
    ingredients: [
      '2 oz gin',
      '1 oz fresh lemon juice',
      '3/4 oz simple syrup',
      'Club soda',
      'Lemon wheel for garnish',
    ],
    recipe: [
      'Add gin, lemon juice, and simple syrup to a shaker with ice',
      'Shake vigorously for 15 seconds',
      'Strain into a Collins glass filled with fresh ice',
      'Top with club soda',
      'Garnish with a lemon wheel',
    ],
    imageUrl: 'https://images.pexels.com/photos/2480828/pexels-photo-2480828.jpeg',
    mood: 'refreshing',
  },
  {
    name: 'Mojito',
    description: 'A refreshing Cuban highball that combines rum, mint, and lime.',
    ingredients: [
      '2 oz white rum',
      '1 oz fresh lime juice',
      '3/4 oz simple syrup',
      '8-10 mint leaves',
      'Club soda',
      'Mint sprig and lime wheel for garnish',
    ],
    recipe: [
      'Gently muddle mint leaves in a shaker',
      'Add rum, lime juice, and simple syrup',
      'Shake with ice and strain into a highball glass with fresh ice',
      'Top with club soda',
      'Garnish with a mint sprig and lime wheel',
    ],
    imageUrl: 'https://images.pexels.com/photos/4021983/pexels-photo-4021983.jpeg',
    mood: 'refreshing',
  },
];

export async function getCocktailSuggestion(
  countryCode: string,
  weatherCondition: string,
  temperature: number
): Promise<CocktailData> {
  try {
    addBreadcrumb(
      `Requesting mood-matched cocktail from city-experience (${countryCode}, ${weatherCondition}, ${temperature}°C)`,
      'cocktail'
    );
    const response = await axios.post(
      `${CITY_API_BASE}/cocktail-match`,
      { countryCode, weatherCondition, temperature },
      { timeout: 20000 }
    );
    return response.data.cocktail as CocktailData;
  } catch (error) {
    addBreadcrumb('Cocktail service unavailable, using local fallback cocktails', 'cocktail');
    // Offline fallback: pick a fallback whose ingredients include a spirit we
    // associate with the country, else a random one.
    const commonSpirits = ['gin', 'rum', 'whiskey', 'vodka'];
    const matching = fallbackCocktails.filter((cocktail) =>
      cocktail.ingredients.some((ingredient) =>
        commonSpirits.some((spirit) => ingredient.toLowerCase().includes(spirit))
      )
    );
    const pool = matching.length > 0 ? matching : fallbackCocktails;
    const selected = pool[Math.floor(Math.random() * pool.length)];
    return { ...selected, mood: 'balanced' };
  }
}