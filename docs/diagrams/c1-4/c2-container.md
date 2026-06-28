# C2 — Container

Shows the deployable units (containers) inside ShopLens and how they communicate.

```mermaid
C4Container
    title ShopLens — Containers

    Person(shopper, "Shopper")

    Container(mobile, "Flutter Mobile App", "Flutter / Dart", "Live scan, tap-to-identify, image upload, voice chat")
    Container(analyzer, "AI Analyzer", "FastAPI / Python (Cloud Run)", "Hosts /analyze, /analyze/stream, /identify — orchestrates Gemini + GCS + Lens")
    Container(matcher, "Product Matcher", "Cloud Run", "Deduplication and ranking of product results")
    Container(voice, "Voice Assistant", "Cloud Run / WebSocket", "STT → intent → Gemini → spoken response")
    Container(ingest, "Live Ingest", "Cloud Run", "Receives live video segments, triggers analyze_media (video path)")

    ContainerDb(firestore, "Cloud Firestore", "NoSQL", "Session data, shopping list, user profile")
    ContainerDb(gcs_store, "Google Cloud Storage", "Object store", "Temp crop images for Lens; 1-day lifecycle delete")

    System_Ext(mlkit, "ML Kit (on-device)", "Zero-latency object bounding boxes — no network")
    System_Ext(gemini, "Google Gemini API", "Detection prompt + describe-crop prompt")
    System_Ext(serpapi, "SerpAPI", "Google Lens + Google Shopping")
    System_Ext(firebase_auth, "Firebase Auth", "JWT tokens")

    Rel(shopper, mobile, "Camera, touch, voice")
    Rel(mobile, mlkit, "Camera frames (on-device, no network)")
    Rel(mobile, analyzer, "POST /analyze or /identify (HTTPS)")
    Rel(mobile, voice, "WebSocket (voice stream)")
    Rel(mobile, firestore, "Session read / write")
    Rel(mobile, firebase_auth, "Auth token")
    Rel(analyzer, gemini, "generate_content API")
    Rel(analyzer, gcs_store, "upload_blob / public URL")
    Rel(analyzer, serpapi, "Lens search + Shopping search")
    Rel(ingest, analyzer, "analyze_media (GCS video URI)")
```

## Key points

- **AI Analyzer is the bottleneck** — it owns the Gemini, GCS, and Lens calls; all latency tuning targets this container
- **ML Kit lives entirely inside the mobile app** — the Analyzer never calls it; the mobile app passes the resulting crop as `image_data`
- **Live Ingest uses the same `analyze_media()` function** as the image path, but on GCS video URIs — Lens is skipped for video
- **Product Matcher and Voice Assistant are separate Cloud Run services** — they are not part of the tap-to-identify or scan-all paths
