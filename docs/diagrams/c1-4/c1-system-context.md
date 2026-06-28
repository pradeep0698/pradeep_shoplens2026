# C1 — System Context

Shows ShopLens as a black box in relation to the people who use it and the external systems it depends on.

```mermaid
C4Context
    title ShopLens — System Context

    Person(shopper, "Shopper", "Points phone camera at products, taps to identify, speaks queries")

    System(shoplens, "ShopLens", "Real-time product scanner. On-device ML detects objects; cloud AI identifies and prices them.")

    System_Ext(mlkit, "Google ML Kit", "On-device object detection — runs locally, no network call")
    System_Ext(gemini, "Google Gemini", "Multimodal LLM — bounding-box detection + crop description")
    System_Ext(gcs, "Google Cloud Storage", "Temporary image host so Google Lens can fetch the crop by URL")
    System_Ext(serpapi, "SerpAPI", "Proxy for Google Lens (visual) and Google Shopping (text fallback)")
    System_Ext(firebase, "Firebase", "Sign-in (Auth) + shopping list persistence (Firestore)")

    Rel(shopper, shoplens, "Live camera, tap, voice")
    Rel(shoplens, mlkit, "Camera frames fed to on-device model")
    Rel(shoplens, gemini, "Image sent for detection / description")
    Rel(shoplens, gcs, "Crop uploaded for Lens access")
    Rel(shoplens, serpapi, "Visual + text product search")
    Rel(shoplens, firebase, "Auth + session storage")
```

## Key points

- **ML Kit is on-device** — no network hop, zero added latency for the live glow overlay
- **GCS is a relay** — images are uploaded only so Lens has a public URL to fetch from; a 1-day bucket lifecycle rule deletes them automatically
- **SerpAPI wraps both Lens and Shopping** — one key, two search modes (visual first, text fallback)
- **Firebase is used only for identity and persistence** — it plays no role in the product-identification pipeline
