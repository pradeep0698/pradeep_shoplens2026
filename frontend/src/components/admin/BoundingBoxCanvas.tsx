'use client';

import { useEffect, useRef } from 'react';

interface Props {
  videoRef: React.RefObject<HTMLVideoElement>;
  onCrop: (base64Jpeg: string, timestamp: number) => void;
  disabled?: boolean;
}

export default function BoundingBoxCanvas({ videoRef, onCrop, disabled }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const drawing = useRef<{ x: number; y: number } | null>(null);

  // Keep canvas pixel dimensions in sync with the video's rendered size.
  useEffect(() => {
    const video = videoRef.current;
    const canvas = canvasRef.current;
    if (!video || !canvas) return;

    function sync() {
      canvas!.width  = video!.offsetWidth;
      canvas!.height = video!.offsetHeight;
    }
    sync();

    const ro = new ResizeObserver(sync);
    ro.observe(video);
    return () => ro.disconnect();
  }, [videoRef]);

  // Clear any in-progress drawing when the canvas becomes disabled (video playing or analyzing).
  useEffect(() => {
    if (disabled) {
      drawing.current = null;
      const canvas = canvasRef.current;
      if (canvas) canvas.getContext('2d')?.clearRect(0, 0, canvas.width, canvas.height);
    }
  }, [disabled]);

  function clientToCanvas(e: React.MouseEvent<HTMLCanvasElement>) {
    const rect = canvasRef.current!.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  }

  function paintRect(x1: number, y1: number, x2: number, y2: number) {
    const canvas = canvasRef.current!;
    const ctx    = canvas.getContext('2d')!;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setLineDash([6, 4]);
    ctx.strokeStyle = '#34D399';
    ctx.lineWidth   = 2;
    ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
    ctx.fillStyle = 'rgba(52,211,153,0.1)';
    ctx.fillRect(x1, y1, x2 - x1, y2 - y1);
  }

  function handleMouseDown(e: React.MouseEvent<HTMLCanvasElement>) {
    if (disabled) return;
    const video = videoRef.current;
    if (!video || video.readyState < 2) return;
    drawing.current = clientToCanvas(e);
  }

  function handleMouseMove(e: React.MouseEvent<HTMLCanvasElement>) {
    if (!drawing.current) return;
    const { x, y } = clientToCanvas(e);
    paintRect(drawing.current.x, drawing.current.y, x, y);
  }

  function handleMouseLeave() {
    if (!drawing.current) return;
    drawing.current = null;
    const canvas = canvasRef.current;
    if (canvas) canvas.getContext('2d')?.clearRect(0, 0, canvas.width, canvas.height);
  }

  function handleMouseUp(e: React.MouseEvent<HTMLCanvasElement>) {
    if (!drawing.current) return;
    const start = drawing.current;
    drawing.current = null;

    const { x: endX, y: endY } = clientToCanvas(e);
    const video  = videoRef.current!;
    const canvas = canvasRef.current!;

    const cropX = Math.min(start.x, endX);
    const cropY = Math.min(start.y, endY);
    const cropW = Math.abs(endX - start.x);
    const cropH = Math.abs(endY - start.y);

    // Ignore tiny accidental clicks.
    if (cropW < 8 || cropH < 8) {
      canvas.getContext('2d')!.clearRect(0, 0, canvas.width, canvas.height);
      return;
    }

    // Map display pixels → video natural pixels.
    const scaleX = video.videoWidth  / canvas.width;
    const scaleY = video.videoHeight / canvas.height;

    const offscreen = document.createElement('canvas');
    offscreen.width  = cropW * scaleX;
    offscreen.height = cropH * scaleY;
    offscreen.getContext('2d')!.drawImage(
      video,
      cropX * scaleX, cropY * scaleY, cropW * scaleX, cropH * scaleY,
      0, 0, offscreen.width, offscreen.height,
    );

    const base64 = offscreen.toDataURL('image/jpeg', 0.85).split(',')[1] ?? '';
    onCrop(base64, video.currentTime);

    canvas.getContext('2d')!.clearRect(0, 0, canvas.width, canvas.height);
  }

  return (
    <canvas
      ref={canvasRef}
      onMouseDown={handleMouseDown}
      onMouseMove={handleMouseMove}
      onMouseUp={handleMouseUp}
      onMouseLeave={handleMouseLeave}
      className={`absolute inset-0 ${disabled ? 'cursor-default' : 'cursor-crosshair'}`}
      style={{ touchAction: 'none' }}
    />
  );
}
