'use client';

import { useRef, useState } from 'react';
import BoundingBoxCanvas from './BoundingBoxCanvas';

const analyzerApiUrl =
  process.env.NEXT_PUBLIC_ANALYZER_API_URL || 'http://localhost:8081';

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

type IdentifyResponse = {
  items: string[];
  products?: AnnotationProduct[];
};

interface Props {
  file: File;
  fileName: string;
  initialAnnotations?: Annotation[];
  onSave: (annotations: Annotation[]) => Promise<void>;
  onBack: () => void;
}

function fmtTime(seconds: number) {
  const m = Math.floor(seconds / 60).toString().padStart(2, '0');
  const s = Math.floor(seconds % 60).toString().padStart(2, '0');
  const ms = Math.floor((seconds % 1) * 10);
  return `${m}:${s}.${ms}`;
}

export default function VideoAnnotator({
  file,
  fileName,
  initialAnnotations = [],
  onSave,
  onBack,
}: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const blobUrl  = useRef(URL.createObjectURL(file)).current;

  const [isPlaying, setIsPlaying]   = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration]     = useState(0);

  const [annotations, setAnnotations] = useState<Annotation[]>(initialAnnotations);
  const [pendingProducts, setPendingProducts] = useState<AnnotationProduct[] | null>(null);
  const [pendingTimestamp, setPendingTimestamp] = useState<number | null>(null);
  const [analyzing, setAnalyzing]   = useState(false);
  const [analyzeError, setAnalyzeError] = useState('');
  const [saving, setSaving]         = useState(false);
  const [saveError, setSaveError]   = useState('');

  // ── Video controls ──────────────────────────────────────────────────────────

  function togglePlay() {
    const v = videoRef.current;
    if (!v) return;
    if (isPlaying) { v.pause(); } else { v.play(); }
  }

  function handleSeek(e: React.ChangeEvent<HTMLInputElement>) {
    const t = parseFloat(e.target.value);
    if (videoRef.current) videoRef.current.currentTime = t;
    setCurrentTime(t);
  }

  // ── Crop & identify ─────────────────────────────────────────────────────────

  async function handleCrop(base64Jpeg: string, timestamp: number) {
    setAnalyzing(true);
    setAnalyzeError('');
    setPendingProducts(null);
    setPendingTimestamp(timestamp);

    try {
      const res = await fetch(`${analyzerApiUrl}/identify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ image_data: base64Jpeg, image_mime_type: 'image/jpeg', ignore_terms: [] }),
      });
      if (!res.ok) throw new Error(`Analyzer error ${res.status}`);
      const data: IdentifyResponse = await res.json();
      const products = data.products ?? [];
      if (products.length === 0) {
        setAnalyzeError('No products identified in this crop. Try a different area.');
      } else {
        setPendingProducts(products);
      }
    } catch (err) {
      setAnalyzeError(err instanceof Error ? err.message : 'Identification failed');
    } finally {
      setAnalyzing(false);
    }
  }

  function addPendingToAnnotations() {
    if (!pendingProducts || pendingTimestamp === null) return;
    setAnnotations((prev) => {
      const next = [...prev, { timestamp: pendingTimestamp, products: pendingProducts }];
      next.sort((a, b) => a.timestamp - b.timestamp);
      return next;
    });
    setPendingProducts(null);
    setPendingTimestamp(null);
  }

  function removeAnnotation(index: number) {
    setAnnotations((prev) => prev.filter((_, i) => i !== index));
  }

  async function handleSave() {
    setSaving(true);
    setSaveError('');
    try {
      await onSave(annotations);
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : 'Save failed');
    } finally {
      setSaving(false);
    }
  }

  // ── Render ───────────────────────────────────────────────────────────────────

  return (
    <div className="flex flex-col gap-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <button type="button" onClick={onBack} className="mb-1 text-xs text-slate-400 hover:text-slate-200">
            ← Back to videos
          </button>
          <h2 className="text-lg font-semibold text-slate-100 truncate max-w-xs">{fileName}</h2>
          <p className="text-xs text-slate-400">Pause video, draw a box around a product, then add it.</p>
        </div>
        <button
          type="button"
          onClick={handleSave}
          disabled={saving || annotations.length === 0}
          className="rounded-full bg-emerald-400 px-5 py-2 text-sm font-semibold text-slate-950 hover:bg-emerald-300 disabled:bg-slate-700 disabled:text-slate-400 disabled:cursor-not-allowed"
        >
          {saving ? 'Saving…' : `Save ${annotations.length} annotation${annotations.length !== 1 ? 's' : ''}`}
        </button>
      </div>

      {saveError && (
        <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 px-4 py-3 text-sm text-rose-200">
          {saveError}
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-[1fr_360px]">
        {/* Video + canvas overlay + custom controls */}
        <div className="rounded-3xl overflow-hidden border border-white/10 bg-black">
          {/* Canvas only covers the video frame — controls live outside this div */}
          <div className="relative w-full">
            <video
              ref={videoRef}
              src={blobUrl}
              className="w-full block"
              onLoadedMetadata={() => setDuration(videoRef.current?.duration ?? 0)}
              onTimeUpdate={() => setCurrentTime(videoRef.current?.currentTime ?? 0)}
              onPlay={() => setIsPlaying(true)}
              onPause={() => setIsPlaying(false)}
              onEnded={() => setIsPlaying(false)}
            />
            <BoundingBoxCanvas
              videoRef={videoRef as React.RefObject<HTMLVideoElement>}
              onCrop={handleCrop}
              disabled={analyzing || isPlaying}
            />
          </div>

          {/* Custom controls — outside the relative div so the canvas never covers them */}
          <div className="flex items-center gap-3 px-4 py-3 bg-slate-900/80">
            <button
              type="button"
              onClick={togglePlay}
              className="flex-shrink-0 w-8 h-8 flex items-center justify-center rounded-full bg-emerald-400 text-slate-950 hover:bg-emerald-300"
            >
              {isPlaying ? (
                <svg className="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
                  <rect x="6" y="4" width="4" height="16" rx="1"/>
                  <rect x="14" y="4" width="4" height="16" rx="1"/>
                </svg>
              ) : (
                <svg className="w-4 h-4 translate-x-0.5" fill="currentColor" viewBox="0 0 24 24">
                  <path d="M8 5v14l11-7z"/>
                </svg>
              )}
            </button>
            <input
              type="range"
              min={0}
              max={duration || 1}
              step={0.05}
              value={currentTime}
              onChange={handleSeek}
              className="flex-1 accent-emerald-400 cursor-pointer"
            />
            <span className="flex-shrink-0 text-xs font-mono text-slate-400 tabular-nums">
              {fmtTime(currentTime)} / {fmtTime(duration)}
            </span>
          </div>

          <p className="px-4 pb-3 text-xs text-slate-500">
            {isPlaying ? 'Pause the video first, then draw a box.' : 'Drag to draw a box around a product.'}
          </p>
        </div>

        {/* Right panel */}
        <div className="space-y-4 overflow-y-auto max-h-[70vh]">
          {analyzing && (
            <div className="rounded-2xl border border-white/10 bg-white/5 p-4 text-sm text-slate-400 animate-pulse">
              Identifying product…
            </div>
          )}

          {analyzeError && (
            <div className="rounded-2xl border border-amber-400/20 bg-amber-400/10 px-4 py-3 text-sm text-amber-200 flex items-start justify-between gap-3">
              <span>{analyzeError} Draw a new box to try again.</span>
              <button
                type="button"
                onClick={() => setAnalyzeError('')}
                className="flex-shrink-0 text-amber-400 hover:text-amber-200 text-base leading-none"
                title="Dismiss"
              >
                ×
              </button>
            </div>
          )}

          {pendingProducts && pendingTimestamp !== null && (
            <div className="rounded-2xl border border-emerald-400/20 bg-emerald-400/5 p-4 space-y-3">
              <div className="flex items-center justify-between gap-2">
                <p className="text-xs text-emerald-300 font-semibold uppercase tracking-wider">
                  Found at {fmtTime(pendingTimestamp)}
                </p>
                <div className="flex gap-2 flex-shrink-0">
                  <button
                    type="button"
                    onClick={() => { setPendingProducts(null); setPendingTimestamp(null); }}
                    className="rounded-full border border-white/20 px-4 py-1.5 text-xs font-semibold text-slate-300 hover:bg-white/10"
                  >
                    Clear
                  </button>
                  <button
                    type="button"
                    onClick={addPendingToAnnotations}
                    className="rounded-full bg-emerald-400 px-4 py-1.5 text-xs font-semibold text-slate-950 hover:bg-emerald-300"
                  >
                    Add to list
                  </button>
                </div>
              </div>
              {pendingProducts.map((p) => (
                <div key={p.product_id} className="flex gap-3 rounded-xl border border-white/10 bg-white/5 p-3">
                  {p.image_url && (
                    <img src={p.image_url} alt={p.name} className="h-12 w-12 rounded-lg object-cover flex-shrink-0" />
                  )}
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-slate-100 leading-tight truncate">{p.name}</p>
                    <p className="text-xs text-emerald-300 mt-0.5">${p.price.toFixed(2)}</p>
                    {p.seller && <p className="text-xs text-slate-500 truncate">{p.seller}</p>}
                    {p.purchase_url && (
                      <a
                        href={p.purchase_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="mt-1 inline-block text-xs font-semibold text-emerald-400 hover:text-emerald-300 underline"
                      >
                        Buy →
                      </a>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}

          <div className="rounded-2xl border border-white/10 bg-white/5 p-4">
            <p className="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-3">
              Saved Annotations ({annotations.length})
            </p>
            {annotations.length === 0 ? (
              <p className="text-xs text-slate-500">No annotations yet. Draw a box on a paused frame to start.</p>
            ) : (
              <div className="space-y-2">
                {annotations.map((ann, i) => (
                  <div key={i} className="flex items-start gap-3 rounded-xl border border-white/10 bg-black/20 p-3">
                    <div className="flex-1 min-w-0">
                      <p className="text-xs text-emerald-300 font-mono">{fmtTime(ann.timestamp)}</p>
                      <p className="text-xs text-slate-300 mt-0.5 truncate">
                        {ann.products.map((p) => p.name).join(', ')}
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => removeAnnotation(i)}
                      className="text-slate-600 hover:text-rose-400 text-xs flex-shrink-0"
                      title="Remove"
                    >
                      ✕
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
