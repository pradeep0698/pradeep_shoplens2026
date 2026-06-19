export type DemoUserSeed = {
  username: string;
  email: string;
  password: string;
  dob: string;
  profile_photo_url?: string;
  gender?: string;
  cooking_skill_level?: string;
  allergies?: string[];
  spice_tolerance_level?: string;
  preferred_meal_prep_time_minutes?: number | null;
  dietary_restrictions?: string[];
  favorite_cuisines?: string[];
  ignore_terms: string[];
  preference_terms: string[];
};

export type UserProfileDocument = {
  username: string;
  dob: string;
  profile_photo_url: string;
  gender: string;
  cooking_skill_level: string;
  allergies: string[];
  spice_tolerance_level: string;
  preferred_meal_prep_time_minutes: number | null;
  dietary_restrictions: string[];
  favorite_cuisines: string[];
  ignore_terms: string[];
  preference_terms: string[];
  shopping_categories?: string[];
  max_searches_per_run?: number;
};

// Hard ceiling on SerpAPI searches per analyze/match run — mirrors
// MAX_SEARCHES_PER_RUN in services/ai-analyzer and services/product-matcher.
// Users can dial it down (1-5) from their profile, never above this.
export const MAX_SEARCHES_PER_RUN = 5;
export const DEFAULT_MAX_SEARCHES_PER_RUN = 5;

export function clampMaxSearches(value: number | null | undefined): number {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return DEFAULT_MAX_SEARCHES_PER_RUN;
  }
  return Math.max(1, Math.min(Math.round(value), MAX_SEARCHES_PER_RUN));
}

export const DEMO_USERS: DemoUserSeed[] = [
  {
    username: 'Bijal M',
    email: '02bijal@gmail.com',
    password: 'Shoplens123!',
    dob: '2000-03-14',
    ignore_terms: ['cilantro'],
    preference_terms: ['mug', 'apron'],
  },
  {
    username: 'Surya R',
    email: 'suryarao.r@gmail.com',
    password: 'Shoplens123!',
    dob: '1978-11-02',
    ignore_terms: ['mushroom'],
    preference_terms: ['garlic', 'pan'],
  },
  {
    username: 'Lakshman S',
    email: 'lsakarayinfo@gmail.com',
    password: 'Shoplens123!',
    dob: '1970-07-23',
    ignore_terms: ['peanut'],
    preference_terms: ['pot', 'basil'],
  },
  {
    username: 'Prabha E',
    email: 'eprabha2019@gmail.com',
    password: 'Shoplens123!',
    dob: '1980-09-08',
    ignore_terms: ['onion'],
    preference_terms: ['cutting board', 'knife'],
  },
];

export function normalizeText(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, ' ');
}

export function normalizeTermList(terms: string[] | null | undefined): string[] {
  if (!terms) {
    return [];
  }

  const normalized: string[] = [];
  const seen = new Set<string>();

  terms.forEach((term) => {
    const value = normalizeText(term);
    if (!value || seen.has(value)) {
      return;
    }

    seen.add(value);
    normalized.push(value);
  });

  return normalized;
}

export function splitTermInput(value: string): string[] {
  return normalizeTermList(
    value
      .split(',')
      .map((term) => term.trim())
      .filter(Boolean)
  );
}

export function joinTermInput(terms: string[] | null | undefined): string {
  return normalizeTermList(terms).join(', ');
}

export function resolveDemoEmail(identifier: string): string {
  const normalized = normalizeText(identifier);
  const match = DEMO_USERS.find((user) => {
    const email = normalizeText(user.email);
    const localPart = normalizeText(user.email.split('@')[0] ?? '');
    return normalized === normalizeText(user.username) || normalized === email || normalized === localPart;
  });

  return match?.email ?? identifier.trim();
}

export function deriveSessionId(uid: string): string {
  return `shoplens-user-${uid}`;
}

export function isPreferredProduct<T extends { name: string; product_id?: string }>(
  product: T,
  preferenceTerms: string[] | null | undefined
): boolean {
  const terms = normalizeTermList(preferenceTerms);
  if (!terms.length) {
    return false;
  }

  const haystack = normalizeText(`${product.name} ${product.product_id ?? ''}`);
  return terms.some((term) => haystack.includes(term));
}

export function rankProductsByPreferences<T extends { name: string; product_id?: string }>(
  products: T[],
  preferenceTerms: string[] | null | undefined
): T[] {
  if (products.length === 0) {
    return [];
  }

  const preferred: T[] = [];
  const other: T[] = [];

  products.forEach((product) => {
    if (isPreferredProduct(product, preferenceTerms)) {
      preferred.push(product);
    } else {
      other.push(product);
    }
  });

  return [...preferred, ...other];
}
