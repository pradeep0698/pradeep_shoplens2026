'use client';

import { useEffect, useRef, useState } from 'react';
import { collection, doc, onSnapshot, serverTimestamp, setDoc, updateDoc } from 'firebase/firestore';
import { auth, db } from '@/lib/firebase';
import VideoAnnotator from '@/components/admin/VideoAnnotator';

type AnnotationProduct = {
  product_id: string;
  name: string;
  price: number;
  image_url: string;
  purchase_url?: string;
  seller?: string;
  category?: string;
};

type Annotation = {
  timestamp: number;
  products: AnnotationProduct[];
};

type VideoDoc = {
  id: string;
  fileName: string;
  videoDownloadUrl?: string;
  status: 'pending' | 'ready';
  uploadedAt: unknown;
  annotations: Annotation[];
};

type View = { mode: 'list' } | { mode: 'annotate'; file: File; fileName: string; initialAnnotations: Annotation[] };

export default function AdminPage() {
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [videos, setVideos] = useState<VideoDoc[]>([]);
  const [view, setView] = useState<View>({ mode: 'list' });
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState('');

  useEffect(() => {
    const unsub = onSnapshot(collection(db, 'VideoAnnotations'), (snap) => {
      const docs = snap.docs.map((d) => ({ id: d.id, ...d.data() } as VideoDoc));
      docs.sort((a, b) => {
        const ta = (a.uploadedAt as { seconds?: number })?.seconds ?? 0;
        const tb = (b.uploadedAt as { seconds?: number })?.seconds ?? 0;
        return tb - ta;
      });
      setVideos(docs);
    });
    return () => unsub();
  }, []);

  async function handleFileSelected(file: File) {
    setUploading(true);
    setUploadError('');

    try {
      const user = auth.currentUser;
      if (!user) throw new Error('Not signed in');

      const fileName = file.name;
      const existing = videos.find(v => v.id === fileName);
      const initialAnnotations = existing?.annotations ?? [];

      // Only save metadata to Firestore — no cloud storage needed (Spark plan compatible).
      // The video is played locally via blob URL; annotations are matched by filename on mobile.
      // Omit annotations from the payload when the doc already exists so we don't overwrite saved data.
      await setDoc(doc(db, 'VideoAnnotations', fileName), {
        fileName,
        status: 'pending',
        uploadedAt: serverTimestamp(),
        uploadedBy: user.uid,
        ...(existing ? {} : { annotations: [] }),
      }, { merge: true });

      setView({ mode: 'annotate', file, fileName, initialAnnotations });
    } catch (err) {
      setUploadError(err instanceof Error ? err.message : 'Could not create annotation entry');
    } finally {
      setUploading(false);
    }
  }

  async function handleSaveAnnotations(fileName: string, annotations: Annotation[]) {
    await updateDoc(doc(db, 'VideoAnnotations', fileName), {
      annotations,
      status: 'ready',
    });
    setView({ mode: 'list' });
  }

  return (
    <main className="min-h-screen bg-[radial-gradient(circle_at_top,_rgba(34,197,94,0.12),_transparent_32%),linear-gradient(180deg,_#0f172a_0%,_#020617_100%)] text-white">
      <header className="flex items-center justify-between border-b border-white/10 bg-slate-950/60 px-6 py-4 backdrop-blur-sm">
        <div className="flex items-center gap-3">
          <img src="/shoplens-logo.png" alt="ShopLens" className="h-[50px] w-auto" />
          <span className="rounded-full border border-emerald-400/30 bg-emerald-400/10 px-3 py-1 text-xs font-semibold text-emerald-300">
            Admin
          </span>
        </div>
        <button
          type="button"
          onClick={async () => {
            const { signOut } = await import('firebase/auth');
            await signOut(auth);
            window.location.href = '/';
          }}
          className="rounded-full border border-white/15 px-3 py-1 text-xs text-slate-300 hover:bg-white/10"
        >
          Sign out
        </button>
      </header>

      <div className="mx-auto max-w-5xl p-6">
        {view.mode === 'annotate' ? (
          <VideoAnnotator
            file={view.file}
            fileName={view.fileName}
            initialAnnotations={view.initialAnnotations}
            onSave={(annotations) => handleSaveAnnotations(view.fileName, annotations)}
            onBack={() => setView({ mode: 'list' })}
          />
        ) : (
          <>
            {/* Dashboard header */}
            <div className="mb-6 flex items-center justify-between">
              <div>
                <h1 className="text-2xl font-semibold tracking-tight">Video Annotations</h1>
                <p className="mt-1 text-sm text-slate-400">
                  Upload a video and annotate products frame by frame.
                </p>
              </div>

              <div>
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="video/*"
                  className="hidden"
                  onChange={(e) => {
                    const file = e.target.files?.[0];
                    if (file) handleFileSelected(file);
                    e.target.value = '';
                  }}
                />
                <button
                  type="button"
                  disabled={uploading}
                  onClick={() => fileInputRef.current?.click()}
                  className="rounded-full bg-emerald-400 px-5 py-2.5 text-sm font-semibold text-slate-950 hover:bg-emerald-300 disabled:bg-slate-700 disabled:text-slate-400 disabled:cursor-not-allowed"
                >
                  {uploading ? 'Loading…' : 'Load & Annotate'}
                </button>
              </div>
            </div>

            {uploadError && (
              <div className="mb-4 rounded-2xl border border-rose-500/30 bg-rose-500/10 px-4 py-3 text-sm text-rose-200">
                {uploadError}
              </div>
            )}

            {/* Video list */}
            {videos.length === 0 ? (
              <div className="flex flex-col items-center justify-center rounded-3xl border border-dashed border-white/15 bg-white/5 py-20 text-center">
                <p className="text-slate-400">No annotated videos yet.</p>
                <p className="mt-1 text-sm text-slate-500">Upload a video to get started.</p>
              </div>
            ) : (
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {videos.map((v) => (
                  <div
                    key={v.id}
                    className="rounded-2xl border border-white/10 bg-white/5 p-4 backdrop-blur"
                  >
                    <div className="flex items-start justify-between gap-2">
                      <p className="text-sm font-medium text-slate-100 break-all leading-snug">
                        {v.fileName}
                      </p>
                      <span
                        className={`flex-shrink-0 rounded-full px-2 py-0.5 text-xs font-semibold ${
                          v.status === 'ready'
                            ? 'bg-emerald-400/15 text-emerald-300'
                            : 'bg-amber-400/15 text-amber-300'
                        }`}
                      >
                        {v.status}
                      </span>
                    </div>
                    <p className="mt-2 text-xs text-slate-500">
                      {v.annotations?.length ?? 0} annotation{v.annotations?.length !== 1 ? 's' : ''}
                    </p>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </div>
    </main>
  );
}
