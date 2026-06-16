'use client';

import { useState } from 'react';

type Props = {
  onSubmit: (username: string, email: string, password: string) => Promise<void>;
  onGoToSignIn: () => void;
  error: string;
  isSubmitting: boolean;
};

export default function SignUpPage({ onSubmit, onGoToSignIn, error, isSubmitting }: Props) {
  const [username, setUsername] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [localError, setLocalError] = useState('');

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();
    setLocalError('');

    if (!username.trim() || !email.trim() || !password.trim() || !confirmPassword.trim()) {
      setLocalError('Fill in username, email, password, and confirm password.');
      return;
    }

    if (password.length < 6) {
      setLocalError('Password must be at least 6 characters.');
      return;
    }

    if (password !== confirmPassword) {
      setLocalError('Passwords do not match.');
      return;
    }

    try {
      await onSubmit(username.trim(), email.trim(), password);
    } catch {
      setLocalError('Sign-up failed. Check your Firebase Auth settings.');
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-[radial-gradient(circle_at_top,_rgba(34,197,94,0.18),_transparent_32%),linear-gradient(180deg,_#0f172a_0%,_#020617_100%)]">
      <div className="w-full max-w-sm rounded-3xl border border-white/10 bg-white/5 p-8 shadow-2xl shadow-black/30 backdrop-blur">
        <div className="mb-8 text-center">
          <div className="mb-4 flex justify-center">
            <img src="/shoplens-logo-nobckg.png" alt="ShopLens" className="h-[120px] w-auto" />
          </div>
          <p className="text-sm text-slate-400">Create your account</p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-slate-300" htmlFor="signup-username">
              Username
            </label>
            <input
              id="signup-username"
              type="text"
              value={username}
              onChange={(event) => {
                setUsername(event.target.value);
                setLocalError('');
              }}
              autoComplete="username"
              className="mt-2 w-full rounded-xl border border-white/10 bg-slate-900 px-4 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400/60"
              placeholder="User Name"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-300" htmlFor="signup-email">
              Email
            </label>
            <input
              id="signup-email"
              type="email"
              value={email}
              onChange={(event) => {
                setEmail(event.target.value);
                setLocalError('');
              }}
              autoComplete="email"
              className="mt-2 w-full rounded-xl border border-white/10 bg-slate-900 px-4 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400/60"
              placeholder="user@shoplens.com"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-300" htmlFor="signup-password">
              Password
            </label>
            <input
              id="signup-password"
              type="password"
              value={password}
              onChange={(event) => {
                setPassword(event.target.value);
                setLocalError('');
              }}
              autoComplete="new-password"
              className="mt-2 w-full rounded-xl border border-white/10 bg-slate-900 px-4 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400/60"
              placeholder="At least 6 characters"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-300" htmlFor="signup-confirm-password">
              Confirm password
            </label>
            <input
              id="signup-confirm-password"
              type="password"
              value={confirmPassword}
              onChange={(event) => {
                setConfirmPassword(event.target.value);
                setLocalError('');
              }}
              autoComplete="new-password"
              className="mt-2 w-full rounded-xl border border-white/10 bg-slate-900 px-4 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400/60"
              placeholder="Re-enter password"
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
            {isSubmitting ? 'Creating account...' : 'Create account'}
          </button>
        </form>

        <div className="mt-5 text-center text-sm text-slate-300">
          Already have an account?{' '}
          <button
            type="button"
            onClick={onGoToSignIn}
            className="font-semibold text-emerald-300 transition-colors hover:text-emerald-200"
          >
            Sign in
          </button>
        </div>
      </div>
    </main>
  );
}
