'use client';

import { useEffect, useState } from 'react';
import { onAuthStateChanged } from 'firebase/auth';
import { doc, getDoc } from 'firebase/firestore';
import { useRouter } from 'next/navigation';
import { auth, db } from '@/lib/firebase';

export default function AdminLayout({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const [allowed, setAllowed] = useState(false);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, async (user) => {
      if (!user) {
        router.push('/');
        return;
      }
      const snap = await getDoc(doc(db, 'UserProfiles', user.uid));
      const role = snap.exists() ? (snap.data() as { role?: string }).role : undefined;
      if (role !== 'admin') {
        router.push('/');
        return;
      }
      setAllowed(true);
    });
    return () => unsubscribe();
  }, [router]);

  if (!allowed) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-950 text-white">
        <div className="rounded-2xl border border-white/10 bg-white/5 px-6 py-4 text-sm text-slate-400 backdrop-blur">
          Checking permissions...
        </div>
      </main>
    );
  }

  return <>{children}</>;
}
