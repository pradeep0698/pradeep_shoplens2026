'use client';

import { useState } from 'react';

type Props = {
  onSubmit: (identifier: string, password: string) => Promise<void>;
  onGoToSignUp: () => void;
  error: string;
  isSubmitting: boolean;
};

export default function LoginPage({ onSubmit, onGoToSignUp, error, isSubmitting }: Props) {
  const [identifier, setIdentifier] = useState('');
  const [password, setPassword] = useState('');
  const [localError, setLocalError] = useState('');

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();

    setLocalError('');
    if (!identifier.trim() || !password.trim()) {
      setLocalError('Enter a username or email and a password.');
      return;
    }

    try {
      await onSubmit(identifier, password);
    } catch {
      setLocalError('Sign-in failed. Check the seeded demo credentials.');
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-[radial-gradient(circle_at_top,_rgba(34,197,94,0.18),_transparent_32%),linear-gradient(180deg,_#0f172a_0%,_#020617_100%)]">
      <div className="w-full max-w-sm rounded-3xl border border-white/10 bg-white/5 p-8 shadow-2xl shadow-black/30 backdrop-blur">
        <div className="mb-8 text-center">
          <div className="flex justify-center">
            <img src="/shoplens-logo.png" alt="ShopLens" className="h-[120px] w-auto" />
          </div>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-slate-300" htmlFor="identifier">
              Email or username
            </label>
            <input
              id="identifier"
              type="text"
              value={identifier}
              onChange={(e) => {
                setIdentifier(e.target.value);
                setLocalError('');
              }}
              autoComplete="username"
              className="mt-2 w-full rounded-xl border border-white/10 bg-slate-900 px-4 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400/60"
              placeholder="user@shoplens.com or User Name"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-300" htmlFor="password">
              Password
            </label>
            <input
              id="password"
              type="password"
              value={password}
              onChange={(e) => {
                setPassword(e.target.value);
                setLocalError('');
              }}
              autoComplete="current-password"
              className="mt-2 w-full rounded-xl border border-white/10 bg-slate-900 px-4 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400/60"
              placeholder="Enter your password"
            />
          </div>

          {(localError || error) && (
            <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 px-4 py-3 text-sm text-rose-200">
              {localError || error}
            </div>
          )}

          <button
            type="submit"
            disabled={isSubmitting}
            className="w-full rounded-full bg-emerald-400 py-3 text-sm font-semibold text-slate-950 transition-colors hover:bg-emerald-300 disabled:cursor-not-allowed disabled:bg-slate-600 disabled:text-slate-300"
          >
            {isSubmitting ? 'Signing in...' : 'Sign in'}
          </button>
        </form>

        <div className="mt-5 text-center text-sm text-slate-300">
          New to ShopLens?{' '}
          <button
            type="button"
            onClick={onGoToSignUp}
            className="font-semibold text-emerald-300 transition-colors hover:text-emerald-200"
          >
            Create an account
          </button>
        </div>
      </div>
    </main>
  );
}
