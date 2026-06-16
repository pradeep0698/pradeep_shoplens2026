'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { createUserWithEmailAndPassword, onAuthStateChanged, signInWithEmailAndPassword, signOut } from 'firebase/auth';
import { collection, doc, onSnapshot, query, setDoc, where } from 'firebase/firestore';
import ShoppingList from '@/components/ShoppingList';
import LoginPage from '@/components/LoginPage';
import SignUpPage from '@/components/SignUpPage';
import ProfilePage from '@/components/ProfilePage';
import { auth, db } from '@/lib/firebase';
import {
  deriveSessionId,
  rankProductsByPreferences,
  resolveDemoEmail,
  type UserProfileDocument,
} from '@/lib/demoProfiles';

const analyzerApiUrl = process.env.NEXT_PUBLIC_ANALYZER_API_URL || 'http://localhost:8081';
const matcherApiUrl = process.env.NEXT_PUBLIC_MATCHER_API_URL || 'http://localhost:8082';
const stateApiUrl = process.env.NEXT_PUBLIC_STATE_API_URL || 'http://localhost:8083';

type Product = {
  product_id: string;
  name: string;
  price: number;
  image_url: string;
  purchase_url?: string;
  seller?: string;
  category?: string;
};

type AnalyzeResponse = {
  items: string[];
  products?: Product[];
  gcs_uri?: string | null;
  image_url?: string | null;
};

type MatchResponse = {
  matched_products: Product[];
  unmatched: string[];
};

type DemoState = {
  items: string[];
  products: Product[];
  unmatchedItems: string[];
  sourceLabel: string;
};

type VideoAnnotation = { timestamp: number; products: Product[] };
type VideoAnnotationDoc = {
  fileName: string;
  status: string;
  annotations: VideoAnnotation[];
  videoDownloadUrl?: string;
};

function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result;
      if (typeof result !== 'string') {
        reject(new Error('Could not read the selected file.'));
        return;
      }
      resolve(result.split(',')[1] ?? '');
    };
    reader.onerror = () => reject(new Error('Could not read the selected file.'));
    reader.readAsDataURL(file);
  });
}

async function requestJson<TResponse>(
  url: string,
  method: 'GET' | 'POST' | 'DELETE',
  body?: unknown
): Promise<TResponse> {
  const response = await fetch(url, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });

  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    const message = typeof payload.detail === 'string' ? payload.detail : `Request failed (${response.status})`;
    throw new Error(message);
  }

  return response.json() as Promise<TResponse>;
}

export default function HomePage() {
  const router = useRouter();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [fileInputKey, setFileInputKey] = useState(0);
  const [authUserId, setAuthUserId] = useState('');
  const [authEmail, setAuthEmail] = useState<string | null>(null);
  const [authLoading, setAuthLoading] = useState(true);
  const [authError, setAuthError] = useState('');
  const [profile, setProfile] = useState<UserProfileDocument | null>(null);
  const [profileLoading, setProfileLoading] = useState(false);
  const [profileError, setProfileError] = useState('');
  const [authMode, setAuthMode] = useState<'login' | 'signup'>('login');
  const [isSigningIn, setIsSigningIn] = useState(false);
  const [isSigningUp, setIsSigningUp] = useState(false);
  const [isSavingProfile, setIsSavingProfile] = useState(false);
  const [view, setView] = useState<'demo' | 'live' | 'profile'>('demo');
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [imageUrl, setImageUrl] = useState('');
  const [previewUrl, setPreviewUrl] = useState('');
  const [status, setStatus] = useState('Ready to analyze an image.');
  const [error, setError] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [demoState, setDemoState] = useState<DemoState | null>(null);

  // Tap-to-identify
  const imgRef    = useRef<HTMLImageElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const drawStart = useRef<{ x: number; y: number } | null>(null);
  const [identifyProducts, setIdentifyProducts] = useState<Product[]>([]);
  const [isIdentifying, setIsIdentifying]       = useState(false);
  const [identifyError, setIdentifyError]       = useState('');

  // Video annotation viewer
  const videoPlayerRef  = useRef<HTMLVideoElement | null>(null);
  const videoFileRef    = useRef<HTMLInputElement | null>(null);
  const [videoAnnotationDocs, setVideoAnnotationDocs]     = useState<VideoAnnotationDoc[]>([]);
  const [videoAnnotationsLoading, setVideoAnnotationsLoading] = useState(false);
  const [selectedVideoDoc, setSelectedVideoDoc]           = useState<VideoAnnotationDoc | null>(null);
  const [videoSrc, setVideoSrc]                           = useState<string | null>(null);
  const [currentProducts, setCurrentProducts]             = useState<Product[]>([]);

  const sessionId = authUserId ? deriveSessionId(authUserId) : '';
  const preferenceTerms = profile?.preference_terms ?? [];
  const ignoreTerms = profile?.ignore_terms ?? [];
  const rankedDemoProducts = useMemo(
    () => rankProductsByPreferences(demoState?.products ?? [], preferenceTerms),
    [demoState?.products, preferenceTerms]
  );

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, (user) => {
      setAuthUserId(user?.uid ?? '');
      setAuthEmail(user?.email ?? null);
      setAuthLoading(false);
      setAuthError('');

      if (!user) {
        setProfile(null);
        setProfileLoading(false);
        setView('demo');
        setSelectedFile(null);
        setImageUrl('');
        setPreviewUrl('');
        setFileInputKey((currentKey) => currentKey + 1);
        setStatus('Ready to analyze an image.');
        setError('');
        setDemoState(null);
        setSelectedVideoDoc(null);
        setVideoSrc(null);
        setCurrentProducts([]);
        setVideoAnnotationDocs([]);
      }
    });

    return () => {
      unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (!authUserId) {
      return;
    }

    setProfileLoading(true);
    setDemoState(null);
    setSelectedFile(null);
    setImageUrl('');
    setPreviewUrl('');
    setFileInputKey((currentKey) => currentKey + 1);
    setStatus('Ready to analyze an image.');
    setError('');

    const profileRef = doc(db, 'UserProfiles', authUserId);
    const unsubscribe = onSnapshot(
      profileRef,
      (snapshot) => {
        if (snapshot.exists()) {
          const data = snapshot.data() as UserProfileDocument & { role?: string };
          if (data.role === 'admin') {
            router.push('/admin');
            return;
          }
          setProfile(data);
        } else {
          setProfile({
            username: authEmail ?? 'User',
            dob: '',
            profile_photo_url: '',
            gender: '',
            cooking_skill_level: '',
            allergies: [],
            spice_tolerance_level: '',
            preferred_meal_prep_time_minutes: null,
            dietary_restrictions: [],
            favorite_cuisines: [],
            ignore_terms: [],
            preference_terms: [],
          });
        }
        setProfileLoading(false);
        setProfileError('');
      },
      (snapshotError) => {
        setProfileError(snapshotError.message);
        setProfileLoading(false);
      }
    );

    return () => {
      unsubscribe();
    };
  }, [authEmail, authUserId]);

  useEffect(() => {
    if (!authUserId) return;
    if (!selectedFile) {
      setPreviewUrl('');
      return;
    }

    const objectUrl = URL.createObjectURL(selectedFile);
    setPreviewUrl(objectUrl);

    return () => URL.revokeObjectURL(objectUrl);
  }, [authUserId, selectedFile]);

  useEffect(() => {
    let active = true;

    if (!authUserId) return;

    async function hydratePersistedState() {
      try {
        const payload = await requestJson<{ products?: Product[] }>(
          `${stateApiUrl}/session/${sessionId}`,
          'GET'
        );

        if (!active) {
          return;
        }

        const products = Array.isArray(payload.products) ? payload.products : [];
        if (products.length > 0) {
          setDemoState({
            items: [],
            products,
            unmatchedItems: [],
            sourceLabel: 'Persisted session',
          });
        }
      } catch {
        // Demo should stay usable even if persistence is unavailable.
      }
    }

    hydratePersistedState();

    return () => {
      active = false;
    };
  }, [authUserId, sessionId]);

  // Load VideoAnnotations from Firestore when entering the video viewer
  useEffect(() => {
    if (view !== 'live' || !authUserId) return;
    setVideoAnnotationsLoading(true);
    const q = query(collection(db, 'VideoAnnotations'), where('status', '==', 'ready'));
    const unsub = onSnapshot(q, (snap) => {
      setVideoAnnotationDocs(
        snap.docs.map((d) => ({ fileName: d.id, ...d.data() } as VideoAnnotationDoc))
      );
      setVideoAnnotationsLoading(false);
    });
    return () => unsub();
  }, [view, authUserId]);

  // Auto-play from stored download URL when one exists
  useEffect(() => {
    if (!selectedVideoDoc) return;
    if (selectedVideoDoc.videoDownloadUrl) {
      setVideoSrc(selectedVideoDoc.videoDownloadUrl);
    } else {
      setVideoSrc(null);
    }
    setCurrentProducts([]);
  }, [selectedVideoDoc]);

  // Revoke blob URL when src changes or component unmounts
  useEffect(() => {
    return () => {
      if (videoSrc && videoSrc.startsWith('blob:')) URL.revokeObjectURL(videoSrc);
    };
  }, [videoSrc]);

  function resolveAnnotationProducts(annotations: VideoAnnotation[], posSeconds: number): Product[] {
    const sorted = [...annotations].sort((a, b) => a.timestamp - b.timestamp);
    const passed = sorted.filter((a) => a.timestamp <= posSeconds + 0.05);
    if (passed.length === 0) return [];
    const latest = passed[passed.length - 1];
    return sorted
      .filter((a) => Math.abs(a.timestamp - latest.timestamp) <= 1.0)
      .flatMap((a) => a.products);
  }

  function handleVideoTimeUpdate() {
    const video = videoPlayerRef.current;
    if (!video || !selectedVideoDoc) return;
    setCurrentProducts(resolveAnnotationProducts(selectedVideoDoc.annotations ?? [], video.currentTime));
  }

  function handleVideoFilePick(file: File) {
    if (videoSrc && videoSrc.startsWith('blob:')) URL.revokeObjectURL(videoSrc);
    setVideoSrc(URL.createObjectURL(file));
    setCurrentProducts([]);
  }

  async function handleLogin(identifier: string, password: string) {
    setIsSigningIn(true);
    setAuthError('');

    try {
      await signInWithEmailAndPassword(auth, resolveDemoEmail(identifier), password);
    } catch (signInError) {
      setAuthError(signInError instanceof Error ? signInError.message : 'Unable to sign in.');
      throw signInError;
    } finally {
      setIsSigningIn(false);
    }
  }

  async function handleSignUp(username: string, email: string, password: string) {
    setIsSigningUp(true);
    setAuthError('');

    try {
      const credentials = await createUserWithEmailAndPassword(auth, email.trim(), password);
      const initialUsername = username.trim() || email.split('@')[0] || 'User';

      await setDoc(
        doc(db, 'UserProfiles', credentials.user.uid),
        {
          username: initialUsername,
          dob: '',
          profile_photo_url: '',
          gender: '',
          cooking_skill_level: '',
          allergies: [],
          spice_tolerance_level: '',
          preferred_meal_prep_time_minutes: null,
          dietary_restrictions: [],
          favorite_cuisines: [],
          ignore_terms: [],
          preference_terms: [],
          role: 'user',
        },
        { merge: true }
      );
    } catch (signUpError) {
      setAuthError(signUpError instanceof Error ? signUpError.message : 'Unable to create account.');
      throw signUpError;
    } finally {
      setIsSigningUp(false);
    }
  }

  async function handleLogout() {
    await signOut(auth);
  }

  async function handleSaveProfile(nextProfile: UserProfileDocument) {
    if (!authUserId) {
      return;
    }

    setIsSavingProfile(true);
    setProfileError('');

    try {
      await setDoc(doc(db, 'UserProfiles', authUserId), nextProfile, { merge: true });
    } catch (saveError) {
      setProfileError(saveError instanceof Error ? saveError.message : 'Unable to save profile.');
      throw saveError;
    } finally {
      setIsSavingProfile(false);
    }
  }

  // Keep canvas pixel size in sync with the rendered image
  function syncCanvas() {
    const img = imgRef.current;
    const canvas = canvasRef.current;
    if (!img || !canvas) return;
    canvas.width  = img.offsetWidth;
    canvas.height = img.offsetHeight;
  }

  function canvasPoint(e: React.MouseEvent<HTMLCanvasElement>) {
    const rect = canvasRef.current!.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  }

  function paintBox(x1: number, y1: number, x2: number, y2: number) {
    const canvas = canvasRef.current!;
    const ctx = canvas.getContext('2d')!;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setLineDash([6, 4]);
    ctx.strokeStyle = '#34D399';
    ctx.lineWidth = 2;
    ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
    ctx.fillStyle = 'rgba(52,211,153,0.10)';
    ctx.fillRect(x1, y1, x2 - x1, y2 - y1);
  }

  function handleCanvasDown(e: React.MouseEvent<HTMLCanvasElement>) {
    setIdentifyProducts([]);
    setIdentifyError('');
    drawStart.current = canvasPoint(e);
  }

  function handleCanvasMove(e: React.MouseEvent<HTMLCanvasElement>) {
    if (!drawStart.current) return;
    const { x, y } = canvasPoint(e);
    paintBox(drawStart.current.x, drawStart.current.y, x, y);
  }

  async function handleCanvasUp(e: React.MouseEvent<HTMLCanvasElement>) {
    if (!drawStart.current) return;
    const start = drawStart.current;
    drawStart.current = null;

    const { x: ex, y: ey } = canvasPoint(e);
    const canvas = canvasRef.current!;
    const img    = imgRef.current!;

    const cropX = Math.min(start.x, ex);
    const cropY = Math.min(start.y, ey);
    const cropW = Math.abs(ex - start.x);
    const cropH = Math.abs(ey - start.y);

    canvas.getContext('2d')!.clearRect(0, 0, canvas.width, canvas.height);
    if (cropW < 8 || cropH < 8) return;

    // Map display pixels → natural image pixels
    const scaleX = img.naturalWidth  / canvas.width;
    const scaleY = img.naturalHeight / canvas.height;

    const offscreen = document.createElement('canvas');
    offscreen.width  = cropW * scaleX;
    offscreen.height = cropH * scaleY;
    offscreen.getContext('2d')!.drawImage(
      img,
      cropX * scaleX, cropY * scaleY, cropW * scaleX, cropH * scaleY,
      0, 0, offscreen.width, offscreen.height,
    );

    const base64 = offscreen.toDataURL('image/jpeg', 0.85).split(',')[1] ?? '';

    setIsIdentifying(true);
    try {
      type IdentifyResp = { products?: Product[] };
      const res = await requestJson<IdentifyResp>(`${analyzerApiUrl}/identify`, 'POST', {
        image_data: base64,
        image_mime_type: 'image/jpeg',
        ignore_terms: ignoreTerms,
      });
      const found = res.products ?? [];
      if (found.length === 0) {
        setIdentifyError('No products found in that area. Try a larger selection.');
      } else {
        setIdentifyProducts(found);
      }
    } catch (err) {
      setIdentifyError(err instanceof Error ? err.message : 'Identification failed.');
    } finally {
      setIsIdentifying(false);
    }
  }

  async function handleAnalyze() {
    if (!authUserId || !profile) {
      setError('Load a profile before analyzing media.');
      return;
    }

    if (!selectedFile && !imageUrl.trim()) {
      setError('Choose an image file or paste an image URL first.');
      return;
    }

    setIsSubmitting(true);
    setError('');
    setStatus('Uploading media...');

    try {
      let analyzeBody: Record<string, unknown>;

      if (selectedFile) {
        const base64 = await fileToBase64(selectedFile);
        analyzeBody = {
          image_data: base64,
          image_mime_type: selectedFile.type || 'image/jpeg',
          ignore_terms: ignoreTerms,
        };
      } else {
        analyzeBody = {
          image_url: imageUrl.trim(),
          ignore_terms: ignoreTerms,
        };
      }

      setStatus('Analyzing image with Gemini + Lens...');
      const analysis = await requestJson<AnalyzeResponse>(`${analyzerApiUrl}/analyze`, 'POST', analyzeBody);

      let finalProducts: Product[] = analysis.products ?? [];
      let unmatchedItems: string[] = [];

      if (finalProducts.length === 0 && (analysis.items ?? []).length > 0) {
        // Lens found nothing — fall back to product-matcher
        setStatus('Matching products...');
        try {
          const matches = await requestJson<MatchResponse>(`${matcherApiUrl}/match`, 'POST', {
            items: analysis.items ?? [],
            ignore_terms: ignoreTerms,
          });
          finalProducts = matches.matched_products ?? [];
          unmatchedItems = matches.unmatched ?? [];
        } catch {
          // matcher not running locally — skip gracefully
        }
      }

      // Persist to session store if available
      setStatus('Saving session state...');
      try {
        await requestJson<{ status: string }>(`${stateApiUrl}/session/${sessionId}/products`, 'POST', {
          products: finalProducts,
        });
      } catch {
        // state manager not running locally — skip gracefully
      }

      setDemoState({
        items: analysis.items ?? [],
        products: finalProducts,
        unmatchedItems,
        sourceLabel: selectedFile ? selectedFile.name : imageUrl.trim(),
      });
      setStatus('Result ready.');
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : 'Unable to process the image.');
      setStatus('Ready to try again.');
    } finally {
      setIsSubmitting(false);
    }
  }

  async function handleReset() {
    if (!sessionId) {
      return;
    }

    setIsSubmitting(true);
    setError('');

    // Clear local UI state immediately so the file picker resets even if backend reset fails.
    setSelectedFile(null);
    setImageUrl('');
    setFileInputKey((currentKey) => currentKey + 1);
    setDemoState(null);
    setStatus('Session reset. Upload a new image to start again.');

    try {
      await requestJson<{ status: string }>(`${stateApiUrl}/session/${sessionId}`, 'DELETE');
      if (fileInputRef.current) {
        fileInputRef.current.value = '';
      }
    } catch (resetError) {
      setError(resetError instanceof Error ? resetError.message : 'Unable to reset the session.');
    } finally {
      setIsSubmitting(false);
    }
  }

  if (authLoading) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-[radial-gradient(circle_at_top,_rgba(34,197,94,0.18),_transparent_32%),linear-gradient(180deg,_#0f172a_0%,_#020617_100%)] text-white">
        <div className="rounded-3xl border border-white/10 bg-white/5 px-6 py-5 text-sm text-slate-300 shadow-2xl shadow-black/30 backdrop-blur">
          Loading Firebase Auth...
        </div>
      </main>
    );
  }

  if (!authUserId) {
    if (authMode === 'signup') {
      return (
        <SignUpPage
          onSubmit={handleSignUp}
          onGoToSignIn={() => {
            setAuthMode('login');
            setAuthError('');
          }}
          error={authError}
          isSubmitting={isSigningUp}
        />
      );
    }

    return (
      <LoginPage
        onSubmit={handleLogin}
        onGoToSignUp={() => {
          setAuthMode('signup');
          setAuthError('');
        }}
        error={authError}
        isSubmitting={isSigningIn}
      />
    );
  }

  return (
    <main className="min-h-screen overflow-hidden bg-[radial-gradient(circle_at_top,_rgba(34,197,94,0.18),_transparent_32%),linear-gradient(180deg,_#0f172a_0%,_#020617_100%)] text-white">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-white/10 bg-slate-950/60 px-6 py-4 backdrop-blur-sm">
        <img src="/shoplens-logo-nobckg.png" alt="ShopLens" className="h-[50px] w-auto" />
        <div className="flex flex-wrap items-center gap-2 text-xs text-slate-200">
          <span className="rounded-full border border-white/10 bg-white/5 px-3 py-1 text-slate-300">
            {profile?.username || authEmail || 'Signed in'}
          </span>
          <button
            type="button"
            onClick={() => setView(view === 'live' ? 'demo' : 'live')}
            className="rounded-full border border-white/15 px-3 py-1 text-slate-300 transition-colors hover:bg-white/10"
          >
            {view === 'live' ? 'Close videos' : 'Watch Videos'}
          </button>
          <button
            type="button"
            onClick={() => setView(view === 'profile' ? 'demo' : 'profile')}
            className="rounded-full border border-white/15 px-3 py-1 text-slate-300 transition-colors hover:bg-white/10"
          >
            {view === 'profile' ? 'Home' : 'Profile'}
          </button>
          <button
            type="button"
            onClick={handleLogout}
            className="rounded-full border border-white/15 px-3 py-1 text-slate-300 transition-colors hover:bg-white/10"
          >
            Sign out
          </button>
        </div>
      </header>

      {view === 'profile' ? (
        <div className="flex min-h-[calc(100vh-64px)] items-start justify-center p-6">

          {profileLoading ? (
            <div className="rounded-3xl border border-white/10 bg-white/5 p-5 text-sm text-slate-300 shadow-2xl shadow-black/20 backdrop-blur">
              Loading profile...
            </div>
          ) : (
            <ProfilePage
              profile={profile}
              sessionId={sessionId}
              currentEmail={authEmail}
              onSave={handleSaveProfile}
              onBackToDemo={() => setView('demo')}
              onSignOut={handleLogout}
              isSaving={isSavingProfile}
              error={profileError}
            />
          )}
        </div>
      ) : view === 'live' ? (
        <div className="grid grid-cols-1 gap-4 p-4 xl:grid-cols-[minmax(0,1.5fr)_320px]">
          <section className="min-w-0 space-y-4" aria-label="Video viewer">

            {/* Video player */}
            <div className="overflow-hidden rounded-3xl border border-white/10 bg-slate-950/50">
              {selectedVideoDoc ? (
                videoSrc ? (
                  <video
                    ref={videoPlayerRef}
                    src={videoSrc}
                    controls
                    className="w-full"
                    onTimeUpdate={handleVideoTimeUpdate}
                  />
                ) : (
                  <div className="flex flex-col items-center justify-center gap-4 p-10 text-center">
                    <p className="text-sm text-slate-300">Upload the matching video file to watch with annotations:</p>
                    <p className="font-mono text-xs text-emerald-300">{selectedVideoDoc.fileName}</p>
                    <label className="cursor-pointer rounded-full bg-emerald-400 px-5 py-2.5 text-sm font-semibold text-slate-950 hover:bg-emerald-300">
                      Choose video file
                      <input
                        ref={videoFileRef}
                        type="file"
                        accept="video/*"
                        className="hidden"
                        onChange={(e) => { const f = e.target.files?.[0]; if (f) handleVideoFilePick(f); }}
                      />
                    </label>
                  </div>
                )
              ) : (
                <div className="flex h-[280px] items-center justify-center text-sm text-slate-400">
                  Select a video from the library below
                </div>
              )}
            </div>

            {/* Video library */}
            <div className="rounded-3xl border border-white/10 bg-white/5 p-5">
              <p className="text-sm uppercase tracking-[0.24em] text-emerald-300/80">Video Library</p>
              {videoAnnotationsLoading ? (
                <p className="mt-3 text-sm text-slate-400">Loading...</p>
              ) : videoAnnotationDocs.length === 0 ? (
                <p className="mt-3 text-sm text-slate-400">No annotated videos yet. Use the admin panel to annotate a video first.</p>
              ) : (
                <div className="mt-3 space-y-2">
                  {videoAnnotationDocs.map((vdoc) => (
                    <button
                      key={vdoc.fileName}
                      type="button"
                      onClick={() => setSelectedVideoDoc(vdoc)}
                      className={`w-full rounded-2xl border px-4 py-3 text-left transition-colors ${
                        selectedVideoDoc?.fileName === vdoc.fileName
                          ? 'border-emerald-400/40 bg-emerald-400/10'
                          : 'border-white/10 bg-white/5 hover:bg-white/10'
                      }`}
                    >
                      <p className="truncate text-sm font-medium text-slate-100">{vdoc.fileName}</p>
                      <p className="mt-0.5 text-xs text-slate-400">
                        {vdoc.annotations?.length ?? 0} annotation{(vdoc.annotations?.length ?? 0) !== 1 ? 's' : ''}
                      </p>
                    </button>
                  ))}
                </div>
              )}
            </div>
          </section>

          {/* Now-showing products */}
          <aside
            className="min-h-[640px] space-y-3 overflow-y-auto rounded-3xl border border-white/10 bg-white/5 p-5 shadow-2xl shadow-black/20 backdrop-blur"
            aria-label="Currently shown products"
          >
            <p className="text-sm uppercase tracking-[0.24em] text-emerald-300/80">Now Showing</p>
            {currentProducts.length === 0 ? (
              <p className="mt-2 text-sm text-slate-400">
                {selectedVideoDoc && videoSrc
                  ? 'Play the video to see products'
                  : 'Select and play a video to see products'}
              </p>
            ) : (
              currentProducts.map((p) => (
                <div key={p.product_id} className="flex gap-3 rounded-2xl border border-white/10 bg-white/5 p-3">
                  {p.image_url && (
                    <img src={p.image_url} alt={p.name} className="h-14 w-14 flex-shrink-0 rounded-xl object-cover" />
                  )}
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium leading-snug text-slate-100">{p.name}</p>
                    <p className="mt-0.5 text-sm text-emerald-300">${(p.price ?? 0).toFixed(2)}</p>
                    {p.seller && <p className="text-xs text-slate-500 truncate">{p.seller}</p>}
                    {p.purchase_url && (
                      <a
                        href={p.purchase_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="mt-1 inline-block text-xs font-semibold text-emerald-400 underline hover:text-emerald-300"
                      >
                        Buy →
                      </a>
                    )}
                  </div>
                </div>
              ))
            )}
          </aside>
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 p-4 xl:grid-cols-[minmax(0,1.5fr)_320px]">
          <section className="min-w-0 space-y-4" aria-label="Demo controls">
            <div className="rounded-3xl border border-white/10 bg-white/5 p-5 shadow-2xl shadow-black/20 backdrop-blur">
              <div className="mb-5 flex items-start justify-between gap-3">
                <div>
                  <p className="text-sm uppercase tracking-[0.24em] text-emerald-300/80">Input</p>
                  <h1 className="mt-1 text-3xl font-semibold tracking-tight">Turn one image into a shoppable result</h1>
                </div>
                <div className="rounded-2xl border border-white/10 bg-black/20 px-4 py-3 text-right">
                  <p className="text-xs uppercase tracking-[0.2em] text-slate-400">Current status</p>
                  <p className="mt-1 text-sm text-slate-100">{isSubmitting ? 'Working...' : status}</p>
                </div>
              </div>

              <div className="grid gap-4 lg:grid-cols-[1.1fr_0.9fr]">
                <div className="space-y-4">
                  <label className="block cursor-pointer rounded-2xl border border-dashed border-white/15 bg-slate-950/40 p-4 transition-colors hover:border-emerald-400/50">
                    <span className="block text-sm font-medium text-slate-200">Upload a cooking image</span>
                    <span className="mt-1 block text-sm text-slate-400">JPG, PNG, or WEBP. This is the fastest path.</span>
                    <input
                      key={fileInputKey}
                      ref={fileInputRef}
                      className="mt-3 block w-full text-sm text-slate-300 file:mr-4 file:rounded-full file:border-0 file:bg-emerald-400 file:px-4 file:py-2 file:text-sm file:font-semibold file:text-slate-950 hover:file:bg-emerald-300"
                      type="file"
                      accept="image/*"
                      onChange={(event) => {
                        setSelectedFile(event.target.files?.[0] ?? null);
                        setError('');
                      }}
                    />
                  </label>

                  <div className="rounded-2xl border border-white/10 bg-slate-950/40 p-4">
                    <label className="block text-sm font-medium text-slate-200" htmlFor="image-url">
                      Or paste an image URL
                    </label>
                    <input
                      id="image-url"
                      type="url"
                      value={imageUrl}
                      onChange={(event) => {
                        setImageUrl(event.target.value);
                        setError('');
                      }}
                      placeholder="https://example.com/cooking-image.jpg"
                      className="mt-3 w-full rounded-xl border border-white/10 bg-slate-900 px-4 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400/60"
                    />
                  </div>

                  <div className="rounded-2xl border border-white/10 bg-slate-950/40 p-4">
                    <div className="flex items-center justify-between gap-3">
                      <div>
                        <p className="text-sm font-medium text-slate-200">Ignore list</p>
                        <p className="mt-1 text-xs text-slate-400">Loaded from the signed-in profile and applied automatically.</p>
                      </div>
                      <button
                        type="button"
                        onClick={() => setView('profile')}
                        className="rounded-full border border-white/15 px-3 py-1 text-xs font-semibold text-slate-200 transition-colors hover:bg-white/10"
                      >
                        Edit profile
                      </button>
                    </div>
                    <div className="mt-3 flex flex-wrap gap-2">
                      {ignoreTerms.length > 0 ? (
                        ignoreTerms.map((term) => (
                          <span key={term} className="rounded-full border border-white/10 bg-white/5 px-3 py-1 text-xs text-slate-200">
                            {term}
                          </span>
                        ))
                      ) : (
                        <p className="text-sm text-slate-500">No ignore terms saved in the current profile.</p>
                      )}
                    </div>
                  </div>

                  <div className="flex flex-wrap gap-3">
                    <button
                      type="button"
                      onClick={handleAnalyze}
                      disabled={(!selectedFile && !imageUrl.trim()) || isSubmitting}
                      className="rounded-full bg-emerald-400 px-5 py-2.5 text-sm font-semibold text-slate-950 transition-colors hover:bg-emerald-300 disabled:cursor-not-allowed disabled:bg-slate-600 disabled:text-slate-300"
                    >
                      Analyze image
                    </button>
                    <button
                      type="button"
                      onClick={handleReset}
                      disabled={isSubmitting}
                      className="rounded-full border border-white/15 px-5 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-white/10 disabled:cursor-not-allowed"
                    >
                      Reset
                    </button>
                  </div>

                  {error && (
                    <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 px-4 py-3 text-sm text-rose-200">
                      {error}
                    </div>
                  )}
                </div>

                <div className="space-y-4">
                  <div className="overflow-hidden rounded-3xl border border-white/10 bg-slate-950/50">
                    {previewUrl ? (
                      <div className="relative">
                        <img
                          ref={imgRef}
                          src={previewUrl}
                          alt="Selected upload"
                          className="block w-full"
                          onLoad={syncCanvas}
                        />
                        <canvas
                          ref={canvasRef}
                          className="absolute inset-0 cursor-crosshair"
                          style={{ touchAction: 'none' }}
                          onMouseDown={handleCanvasDown}
                          onMouseMove={handleCanvasMove}
                          onMouseUp={handleCanvasUp}
                        />
                        {isIdentifying && (
                          <div className="absolute inset-0 flex items-center justify-center bg-black/50">
                            <div className="rounded-2xl bg-slate-900/90 px-4 py-3 text-sm text-slate-300">Identifying…</div>
                          </div>
                        )}
                        <div className="absolute bottom-2 right-2 rounded-full bg-black/60 px-3 py-1 text-xs text-slate-300 backdrop-blur">
                          Drag to identify a product
                        </div>
                      </div>
                    ) : (
                      <div className="flex h-[280px] flex-col items-center justify-center gap-3 px-8 text-center text-slate-400">
                        <div className="flex h-14 w-14 items-center justify-center rounded-2xl border border-white/10 bg-white/5 text-emerald-300">
                          <svg className="h-7 w-7" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5}
                              d="M2.25 15.75l5.159-5.159a2.25 2.25 0 013.182 0l5.159 5.159m-1.5-1.5l1.409-1.409a2.25 2.25 0 013.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 001.5-1.5V6a1.5 1.5 0 00-1.5-1.5H3.75A1.5 1.5 0 002.25 6v12a1.5 1.5 0 001.5 1.5z"
                            />
                          </svg>
                        </div>
                        <p className="text-sm font-medium text-slate-300">Upload an image to preview it here</p>
                        <p className="text-xs leading-5 text-slate-500">Upload an image, then drag on it to identify specific products — or click Analyze image to detect everything at once.</p>
                      </div>
                    )}
                  </div>

                  {identifyError && (
                    <div className="rounded-2xl border border-amber-400/20 bg-amber-400/10 px-4 py-3 text-sm text-amber-200">
                      {identifyError}
                    </div>
                  )}

                  {identifyProducts.length > 0 && (
                    <div className="rounded-2xl border border-emerald-400/20 bg-emerald-400/5 p-4 space-y-3">
                      <p className="text-xs font-semibold uppercase tracking-wider text-emerald-300">Tap-to-identify result</p>
                      {identifyProducts.map((p) => (
                        <div key={p.product_id} className="flex gap-3 rounded-xl border border-white/10 bg-white/5 p-3">
                          {p.image_url && (
                            <img src={p.image_url} alt={p.name} className="h-12 w-12 flex-shrink-0 rounded-lg object-cover" />
                          )}
                          <div className="min-w-0 flex-1">
                            <p className="text-sm font-medium text-slate-100 leading-tight">{p.name}</p>
                            <p className="text-xs text-emerald-300 mt-0.5">${(p.price ?? 0).toFixed(2)}</p>
                            {p.seller && <p className="text-xs text-slate-500 truncate">{p.seller}</p>}
                            {p.purchase_url && (
                              <a href={p.purchase_url} target="_blank" rel="noopener noreferrer"
                                className="mt-1 inline-block text-xs font-semibold text-emerald-400 hover:text-emerald-300 underline">
                                Buy →
                              </a>
                            )}
                          </div>
                        </div>
                      ))}
                    </div>
                  )}

                  <div className="grid gap-3 sm:grid-cols-3">
                    <div className="rounded-2xl border border-white/10 bg-white/5 p-4">
                      <p className="text-xs uppercase tracking-[0.2em] text-slate-400">Detected items</p>
                      <p className="mt-2 text-2xl font-semibold">{demoState?.items.length ?? 0}</p>
                    </div>
                    <div className="rounded-2xl border border-white/10 bg-white/5 p-4">
                      <p className="text-xs uppercase tracking-[0.2em] text-slate-400">Matched products</p>
                      <p className="mt-2 text-2xl font-semibold">{demoState?.products.length ?? 0}</p>
                    </div>
                    <div className="rounded-2xl border border-white/10 bg-white/5 p-4">
                      <p className="text-xs uppercase tracking-[0.2em] text-slate-400">Source</p>
                      <p className="mt-2 break-all text-sm font-medium text-slate-200">{demoState?.sourceLabel || 'None yet'}</p>
                    </div>
                  </div>
                </div>
              </div>

              {demoState && (
                <div className="mt-5 grid gap-4 lg:grid-cols-[0.9fr_1.1fr]">
                  <div className="rounded-3xl border border-white/10 bg-slate-950/40 p-4">
                    <p className="text-sm font-semibold text-slate-100">Detected items</p>
                    <div className="mt-3 flex flex-wrap gap-2">
                      {demoState.items.length > 0 ? (
                        demoState.items.map((item) => (
                          <span key={item} className="rounded-full border border-emerald-400/20 bg-emerald-400/10 px-3 py-1 text-sm text-emerald-100">
                            {item}
                          </span>
                        ))
                      ) : (
                        <p className="text-sm text-slate-500">No items detected yet.</p>
                      )}
                    </div>
                    {demoState.unmatchedItems.length > 0 && (
                      <div className="mt-4 rounded-2xl border border-amber-400/20 bg-amber-400/10 p-3 text-sm text-amber-100">
                        Unmatched: {demoState.unmatchedItems.join(', ')}
                      </div>
                    )}
                  </div>

                  <div className="rounded-3xl border border-white/10 bg-slate-950/40 p-4">
                    <p className="text-sm font-semibold text-slate-100">Matched products</p>
                    <div className="mt-3 grid gap-3 sm:grid-cols-2">
                      {rankedDemoProducts.length > 0 ? (
                        (rankedDemoProducts as Product[]).map((product) => (
                          <div key={product.product_id} className="flex gap-3 rounded-2xl border border-white/10 bg-white/5 p-3">
                            {product.image_url && (
                              <img src={product.image_url} alt={product.name} className="h-14 w-14 flex-shrink-0 rounded-xl object-cover" />
                            )}
                            <div className="min-w-0 flex-1">
                              <p className="font-medium leading-snug text-sm truncate">{product.name}</p>
                              <p className="mt-0.5 text-sm text-emerald-300">${(product.price ?? 0).toFixed(2)}</p>
                              {product.seller && <p className="text-xs text-slate-500 truncate">{product.seller}</p>}
                              {product.purchase_url && (
                                <a href={product.purchase_url} target="_blank" rel="noopener noreferrer"
                                  className="mt-1 inline-block text-xs font-semibold text-emerald-400 hover:text-emerald-300 underline">
                                  Buy →
                                </a>
                              )}
                            </div>
                          </div>
                        ))
                      ) : (
                        <p className="text-sm text-slate-500">Matched products will appear here after analysis.</p>
                      )}
                    </div>
                  </div>
                </div>
              )}
            </div>
          </section>

          <aside className="min-h-[640px] overflow-hidden rounded-3xl border border-white/10 bg-white/5 shadow-2xl shadow-black/20 backdrop-blur" aria-label="Persisted shopping list">
            <ShoppingList sessionId={sessionId} preferenceTerms={preferenceTerms} />
          </aside>
        </div>
      )}
    </main>
  );
}
