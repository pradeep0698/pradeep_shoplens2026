'use client';

import { useEffect, useState } from 'react';
import {
  clampMaxSearches,
  joinTermInput,
  MAX_SEARCHES_PER_RUN,
  splitTermInput,
  type UserProfileDocument,
} from '@/lib/demoProfiles';

const GENDER_OPTIONS = ['Woman', 'Man', 'Non-binary', 'Prefer not to say'];
const CATEGORY_OPTIONS = [
  'Furniture',
  'Clothing',
  'Kitchen & Cookware',
  'Accessories',
  'Electronics',
  'Home Decor',
  'Sports & Outdoors',
  'Books & Stationery',
];

type FormState = {
  username: string;
  dob: string;
  profilePhotoUrl: string;
  gender: string;
  shoppingCategories: Set<string>;
  ignoreTermsText: string;
  preferenceTermsText: string;
  maxSearches: number;
};

type Props = {
  profile: UserProfileDocument | null;
  sessionId: string;
  currentEmail: string | null;
  onSave: (profile: UserProfileDocument) => Promise<void>;
  onBackToDemo: () => void;
  onSignOut: () => Promise<void>;
  isSaving: boolean;
  error: string;
};

function buildFormState(profile: UserProfileDocument | null): FormState {
  return {
    username: profile?.username ?? '',
    dob: profile?.dob ?? '',
    profilePhotoUrl: profile?.profile_photo_url ?? '',
    gender: profile?.gender ?? '',
    shoppingCategories: new Set(profile?.shopping_categories ?? []),
    ignoreTermsText: joinTermInput(profile?.ignore_terms),
    preferenceTermsText: joinTermInput(profile?.preference_terms),
    maxSearches: clampMaxSearches(profile?.max_searches_per_run),
  };
}

export default function ProfilePage({
  profile,
  currentEmail,
  onSave,
  onBackToDemo,
  onSignOut,
  isSaving,
  error,
}: Props) {
  const [form, setForm] = useState<FormState>(() => buildFormState(profile));
  const [localError, setLocalError] = useState('');

  useEffect(() => {
    setForm(buildFormState(profile));
  }, [profile]);

  function set<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setLocalError('');
  }

  function toggleCategory(cat: string) {
    setForm((prev) => {
      const next = new Set(prev.shoppingCategories);
      if (next.has(cat)) { next.delete(cat); } else { next.add(cat); }
      return { ...prev, shoppingCategories: next };
    });
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLocalError('');
    if (!form.username.trim()) { setLocalError('Username is required.'); return; }
    if (!form.dob.trim()) { setLocalError('Date of birth is required.'); return; }

    await onSave({
      // Preserve fields not shown in this form
      cooking_skill_level: profile?.cooking_skill_level ?? '',
      allergies: profile?.allergies ?? [],
      spice_tolerance_level: profile?.spice_tolerance_level ?? '',
      preferred_meal_prep_time_minutes: profile?.preferred_meal_prep_time_minutes ?? null,
      dietary_restrictions: profile?.dietary_restrictions ?? [],
      favorite_cuisines: profile?.favorite_cuisines ?? [],
      // Editable fields
      username: form.username.trim(),
      dob: form.dob.trim(),
      profile_photo_url: form.profilePhotoUrl.trim(),
      gender: form.gender.trim(),
      shopping_categories: Array.from(form.shoppingCategories),
      ignore_terms: splitTermInput(form.ignoreTermsText),
      preference_terms: splitTermInput(form.preferenceTermsText),
      max_searches_per_run: clampMaxSearches(form.maxSearches),
    });
  }

  const photoUrl = form.profilePhotoUrl.trim();
  const initial = (form.username.trim() || 'U').charAt(0).toUpperCase();

  return (
    <div className="mx-auto max-w-md w-full">
      {/* Email strip */}
      {currentEmail && (
        <p className="mb-4 text-xs text-slate-500">{currentEmail}</p>
      )}

      {/* Avatar */}
      <div className="mb-6 flex justify-center">
        <div className="relative h-20 w-20 overflow-hidden rounded-full border border-white/10 bg-slate-900">
          {photoUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={photoUrl} alt="Profile" className="h-full w-full object-cover" />
          ) : (
            <div className="flex h-full w-full items-center justify-center text-2xl font-semibold text-emerald-300">
              {initial}
            </div>
          )}
        </div>
      </div>

      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Username */}
        <Field label="Username">
          <input
            type="text"
            value={form.username}
            onChange={(e) => set('username', e.target.value)}
            placeholder="Ava Chen"
            className={inputCls}
          />
        </Field>

        {/* Date of birth */}
        <Field label="Date of birth (YYYY-MM-DD)">
          <input
            type="date"
            value={form.dob}
            onChange={(e) => set('dob', e.target.value)}
            className={inputCls}
          />
        </Field>

        {/* Photo URL */}
        <Field label="Photo URL">
          <input
            type="url"
            value={form.profilePhotoUrl}
            onChange={(e) => set('profilePhotoUrl', e.target.value)}
            placeholder="https://example.com/avatar.jpg"
            className={inputCls}
          />
        </Field>

        {/* Gender */}
        <Field label="Gender">
          <select
            value={form.gender}
            onChange={(e) => set('gender', e.target.value)}
            className={inputCls}
          >
            <option value="" disabled className="bg-slate-900">Select…</option>
            {GENDER_OPTIONS.map((o) => (
              <option key={o} value={o} className="bg-slate-900">{o}</option>
            ))}
          </select>
        </Field>

        {/* Shopping categories */}
        <div>
          <p className={labelCls}>Shopping preferences</p>
          <p className="mb-2 text-xs text-slate-500">Select the categories you shop for</p>
          <div className="flex flex-wrap gap-2">
            {CATEGORY_OPTIONS.map((cat) => {
              const selected = form.shoppingCategories.has(cat);
              return (
                <button
                  key={cat}
                  type="button"
                  onClick={() => toggleCategory(cat)}
                  className={`rounded-full border px-3.5 py-1.5 text-sm font-medium transition-colors ${
                    selected
                      ? 'border-emerald-400 bg-emerald-400/15 text-emerald-300'
                      : 'border-white/10 bg-white/5 text-slate-300 hover:bg-white/10'
                  }`}
                >
                  {cat}
                </button>
              );
            })}
          </div>
        </div>

        {/* Ignore terms */}
        <Field label="Ignore terms" hint="Hidden from analysis and matching">
          <textarea
            value={form.ignoreTermsText}
            onChange={(e) => set('ignoreTermsText', e.target.value)}
            placeholder="item1, item2"
            rows={3}
            className={inputCls}
          />
        </Field>

        {/* Preference terms */}
        <Field label="Preference terms" hint="These matches float to the top">
          <textarea
            value={form.preferenceTermsText}
            onChange={(e) => set('preferenceTermsText', e.target.value)}
            placeholder="item1, item2"
            rows={3}
            className={inputCls}
          />
        </Field>

        {(localError || error) && (
          <div className="rounded-xl border border-rose-500/30 bg-rose-500/10 px-4 py-3 text-sm text-rose-200">
            {localError || error}
          </div>
        )}

        <button
          type="submit"
          disabled={isSaving}
          className="w-full rounded-full bg-emerald-400 py-3.5 text-sm font-bold text-slate-950 transition-colors hover:bg-emerald-300 disabled:cursor-not-allowed disabled:bg-slate-600 disabled:text-slate-400"
        >
          {isSaving ? 'Saving...' : 'Save profile'}
        </button>

        <div className="flex gap-3 pt-1">
          <button
            type="button"
            onClick={onBackToDemo}
            className="flex-1 rounded-full border border-white/15 py-2.5 text-sm font-semibold text-slate-300 transition-colors hover:bg-white/10"
          >
            Back to home
          </button>
          <button
            type="button"
            onClick={onSignOut}
            className="flex-1 rounded-full border border-white/15 py-2.5 text-sm font-semibold text-slate-300 transition-colors hover:bg-white/10"
          >
            Sign out
          </button>
        </div>
      </form>
    </div>
  );
}

const labelCls = 'mb-1.5 block text-sm font-medium text-slate-300';
const inputCls =
  'w-full rounded-xl border border-white/10 bg-slate-950 px-3.5 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-300';

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div>
      <label className={labelCls}>{label}</label>
      {children}
      {hint && <p className="mt-1 text-xs text-slate-500">{hint}</p>}
    </div>
  );
}
