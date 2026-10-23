// city-experience — cocktail mood-matching port.
// Ported from src/services/cocktailService.ts: the country → spirit
// preferences, the weather-condition → mood map, TheCocktailDB search
// (by preferred spirit, then random, then hardcoded fallbacks) and the
// ingredient/recipe mapping all move SERVER-SIDE. This is the piece the
// assessment brief calls "matching cocktail to the mood of the city".

import axios from 'axios';

const API_BASE_URL = 'https://www.thecocktaildb.com/api/json/v1/1';

// Country drink preferences (verbatim from the FE service)
const countryDrinkPreferences: Record<string, string[]> = {
  us: ['Whiskey', 'Bourbon', 'Rum'],
  gb: ['Gin', 'Whisky', 'Beer'],
  fr: ['Wine', 'Cognac', 'Champagne'],
  it: ['Wine', 'Amaro', 'Vermouth'],
  jp: ['Sake', 'Whisky', 'Umeshu'],
  mx: ['Tequila', 'Mezcal', 'Rum'],
  ru: ['Vodka', 'Kvass', 'Beer'],
  au: ['Beer', 'Wine', 'Rum'],
  ca: ['Whisky', 'Beer', 'Ice Wine'],
  de: ['Beer', 'Schnapps', 'Jägermeister'],
  es: ['Sangria', 'Wine', 'Sherry'],
  ie: ['Guinness', 'Irish Whiskey', 'Baileys'],
  br: ['Cachaça', 'Caipirinha', 'Beer'],
  cn: ['Baijiu', 'Huangjiu', 'Beer'],
  kr: ['Soju', 'Makgeolli', 'Beer'],
  in: ['Whisky', 'Beer', 'Rum'],
  nl: ['Jenever', 'Beer', 'Advocaat'],
  gr: ['Ouzo', 'Metaxa', 'Retsina'],
  se: ['Akvavit', 'Vodka', 'Punsch'],
  pl: ['Vodka', 'Mead', 'Beer'],
  ar: ['Wine', 'Fernet', 'Beer'],
  za: ['Wine', 'Brandy', 'Amarula'],
  pe: ['Pisco', 'Chicha de Jora', 'Beer'],
  tr: ['Rakı', 'Wine', 'Beer'],
  cu: ['Rum', 'Mojito', 'Daiquiri'],
  nz: ['Wine', 'Beer', 'Sauvignon Blanc'],
  il: ['Wine', 'Arak', 'Beer'],
  ua: ['Horilka', 'Vodka', 'Beer'],
  by: ['Vodka', 'Samogon', 'Beer'],
  lt: ['Vodka', 'Mead', 'Beer'],
  lv: ['Vodka', 'Riga Black Balsam', 'Beer'],
  bg: ['Rakia', 'Wine', 'Beer'],
};

const defaultPreferences = ['Gin', 'Vodka', 'Rum', 'Whiskey'];

// Mood mapping based on weather conditions (verbatim)
const weatherMoodMap: Record<string, string[]> = {
  snow: ['cozy', 'warm', 'comforting'],
  rain: ['moody', 'reflective', 'relaxing'],
  cloudy: ['balanced', 'versatile', 'refreshing'],
  sunny: ['bright', 'energetic', 'refreshing'],
  hot: ['cooling', 'refreshing', 'light'],
  cold: ['warming', 'cozy', 'rich'],
  windy: ['dynamic', 'earthy', 'complex'],
  foggy: ['mysterious', 'subtle', 'complex'],
  stormy: ['bold', 'intense', 'complex'],
};

// Fallback cocktails in case the API fails (verbatim)
const fallbackCocktails = [
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

export interface CocktailData {
  name: string;
  description: string;
  ingredients: string[];
  recipe: string[];
  imageUrl: string;
  mood: string;
}

interface CocktailAPIResponse {
  drinks:
    | Array<{
        idDrink: string;
        strDrink: string;
        strDrinkThumb: string;
        strInstructions: string;
        [key: string]: any;
      }>
    | null;
}

async function searchCocktailsByIngredient(ingredient: string): Promise<CocktailAPIResponse> {
  const response = await axios.get(`${API_BASE_URL}/filter.php`, {
    params: { i: ingredient },
    timeout: 10000,
  });
  return response.data;
}

async function getCocktailDetails(cocktailId: string): Promise<CocktailAPIResponse> {
  const response = await axios.get(`${API_BASE_URL}/lookup.php`, {
    params: { i: cocktailId },
    timeout: 10000,
  });
  return response.data;
}

async function getRandomCocktail(): Promise<CocktailAPIResponse> {
  const response = await axios.get(`${API_BASE_URL}/random.php`, { timeout: 10000 });
  return response.data;
}

function mapApiResponseToCocktailData(apiCocktail: any, mood: string): CocktailData {
  const ingredients: string[] = [];
  for (let i = 1; i <= 15; i++) {
    const ingredient = apiCocktail[`strIngredient${i}`];
    const measure = apiCocktail[`strMeasure${i}`];
    if (ingredient && ingredient.trim()) {
      const formattedIngredient =
        measure && measure.trim() ? `${measure.trim()} ${ingredient.trim()}` : ingredient.trim();
      ingredients.push(formattedIngredient);
    }
  }

  const instructions = apiCocktail.strInstructions || '';
  const recipe = instructions
    .split(/[.!?]+/)
    .map((step: string) => step.trim())
    .filter((step: string) => step.length > 0)
    .map((step: string) => step.charAt(0).toUpperCase() + step.slice(1));

  const description =
    instructions.length > 100
      ? instructions.substring(0, 100) + '...'
      : instructions || `A delicious ${apiCocktail.strDrink} cocktail.`;

  return {
    name: apiCocktail.strDrink,
    description,
    ingredients,
    recipe: recipe.length > 0 ? recipe : ['Mix all ingredients and serve'],
    imageUrl: apiCocktail.strDrinkThumb || 'https://images.pexels.com/photos/5379228/pexels-photo-5379228.jpeg',
    mood,
  };
}

function determineMood(weatherCondition: string, temperature: number): string {
  const condition = weatherCondition.toLowerCase();

  if (condition.includes('snow') || condition.includes('sleet')) {
    return weatherMoodMap.snow[Math.floor(Math.random() * weatherMoodMap.snow.length)];
  } else if (condition.includes('rain') || condition.includes('drizzle')) {
    return weatherMoodMap.rain[Math.floor(Math.random() * weatherMoodMap.rain.length)];
  } else if (condition.includes('cloud') || condition.includes('overcast')) {
    return weatherMoodMap.cloudy[Math.floor(Math.random() * weatherMoodMap.cloudy.length)];
  } else if (condition.includes('sunny') || condition.includes('clear')) {
    return weatherMoodMap.sunny[Math.floor(Math.random() * weatherMoodMap.sunny.length)];
  } else if (temperature > 25) {
    return weatherMoodMap.hot[Math.floor(Math.random() * weatherMoodMap.hot.length)];
  } else if (temperature < 5) {
    return weatherMoodMap.cold[Math.floor(Math.random() * weatherMoodMap.cold.length)];
  } else if (condition.includes('wind')) {
    return weatherMoodMap.windy[Math.floor(Math.random() * weatherMoodMap.windy.length)];
  } else if (condition.includes('fog') || condition.includes('mist')) {
    return weatherMoodMap.foggy[Math.floor(Math.random() * weatherMoodMap.foggy.length)];
  } else if (condition.includes('thunder') || condition.includes('storm')) {
    return weatherMoodMap.stormy[Math.floor(Math.random() * weatherMoodMap.stormy.length)];
  } else {
    return 'balanced';
  }
}

function pickFallback(preferredSpirits: string[], mood: string): CocktailData {
  const matchingFallbacks = fallbackCocktails.filter((cocktail) =>
    preferredSpirits.some((spirit) =>
      cocktail.ingredients.some((ingredient) => ingredient.toLowerCase().includes(spirit.toLowerCase()))
    )
  );
  if (matchingFallbacks.length > 0) {
    const selected = matchingFallbacks[Math.floor(Math.random() * matchingFallbacks.length)];
    return { ...selected, mood };
  }
  const fallback = fallbackCocktails[Math.floor(Math.random() * fallbackCocktails.length)];
  return { ...fallback, mood };
}

// Main function — same flow as the FE original: preferred spirits by country,
// mood by weather, spirit search → random → fallback.
export async function getCocktailSuggestion(
  countryCode: string,
  weatherCondition: string,
  temperature: number
): Promise<CocktailData> {
  const preferredSpirits = countryDrinkPreferences[countryCode.toLowerCase()] || defaultPreferences;
  const mood = determineMood(weatherCondition, temperature);

  try {
    for (const spirit of preferredSpirits) {
      try {
        let apiIngredient = spirit;
        if (spirit === 'Whisky') apiIngredient = 'Whiskey';
        if (spirit === 'Cachaça') apiIngredient = 'Cachaca';
        if (spirit === 'Rakı') apiIngredient = 'Raki';

        const cocktailsResponse = await searchCocktailsByIngredient(apiIngredient);

        if (cocktailsResponse.drinks && cocktailsResponse.drinks.length > 0) {
          const randomCocktail =
            cocktailsResponse.drinks[Math.floor(Math.random() * cocktailsResponse.drinks.length)];

          const detailsResponse = await getCocktailDetails(randomCocktail.idDrink);

          if (detailsResponse.drinks && detailsResponse.drinks.length > 0) {
            return mapApiResponseToCocktailData(detailsResponse.drinks[0], mood);
          }
        }
      } catch {
        continue; // next spirit
      }
    }

    const randomResponse = await getRandomCocktail();
    if (randomResponse.drinks && randomResponse.drinks.length > 0) {
      return mapApiResponseToCocktailData(randomResponse.drinks[0], mood);
    }

    return pickFallback(preferredSpirits, mood);
  } catch (error) {
    console.error('Error fetching cocktail from API, using fallback:', error);
    return pickFallback(preferredSpirits, mood);
  }
}