# CookShop MVP — Project Architecture

> AI-powered live shopping platform: point a camera at a video or live stream, get real-time shoppable product matches.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Platform Environments](#2-platform-environments)
3. [Code Structure](#3-code-structure)
4. [Infrastructure](#4-infrastructure)
5. [Data Model (Firestore)](#5-data-model-firestore)
6. [How Everything Connects](#6-how-everything-connects)
7. [CI/CD Pipeline](#7-cicd-pipeline)
8. [Authentication & Authorization](#8-authentication--authorization)

---

## 1. System Overview

CookShop MVP has three client-facing surfaces and a four-service backend on GCP.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Clients                                                            │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────┐   │
│  │ Flutter App  │  │  Next.js Web │  │  Admin (same web app)  │   │
│  │ iOS/Android  │  │  React/TS    │  │  role=admin users      │   │
│  │ + Flutter Web│  │  Firebase    │  │                        │   │
│  └──────┬───────┘  └──────┬───────┘  └───────────┬────────────┘   │
└─────────┼─────────────────┼──────────────────────┼────────────────┘
          │                 │                       │
          │  REST (Dio/fetch)                       │  Firestore SDK
          │                 │                       │
┌─────────▼─────────────────▼───────────────────────▼────────────────┐
│  Firebase (Managed by Google)                                       │
│  ├── Authentication (Email/Password)                                │
│  └── Firestore (Real-time NoSQL)                                    │
│       UserProfiles / LiveShoppingSessions / VideoAnnotations        │
└──────────────────────────────┬──────────────────────────────────────┘
                               │  onSnapshot real-time listeners
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  GCP Cloud Run Services (Python/FastAPI)                             │
│                                                                      │
│  pubsub-worker ──► ai-analyzer ──► product-matcher ──► state-manager│
│       ▲                 │                                   │        │
│       │            Vertex AI                           Firestore     │
│  Pub/Sub push      Gemini 2.0 Flash                  (write session) │
│  (GCS trigger)     Google Lens                                       │
└──────────────────────────────────────────────────────────────────────┘
          ▲
          │
┌─────────┴──────────────────┐
│  Live Video Pipeline        │
│  OBS/Camera → RTMP →        │
│  Cloud Live Stream API →    │
│  Cloud Storage (HLS) →      │
│  Pub/Sub Object Notification│
└─────────────────────────────┘
```

---

## 2. Platform Environments

| Dimension | **Dev** | **Prod** |
|-----------|---------|----------|
| GCP Project | `cookshop-dev-prj-bd7e2` | `cookshop-poc-prj` |
| Firebase alias | `dev` | `prod` / `default` |
| Firebase Hosting | `cookshop-dev-prj-bd7e2.web.app` | `cookshop-poc-prj.web.app` |
| Cloud Run region | `us-central1` | `us-central1` |
| Deploy trigger | push to `develop` | push to `main` or `release/**` |
| Preview deploys | `feature/**`, `fix/**`, PRs → dev preview channel (7-day TTL) | — |

**GitHub Secrets required per environment (`dev` / `prod`):**
- `WIF_PROVIDER` — Workload Identity Federation provider
- `WIF_SERVICE_ACCOUNT` — Service account for CI
- `SA_EMAIL` — Service account email (used for Cloud Run)
- `IMGBB_KEY`, `SERPAPI_KEY` — Third-party API keys injected into ai-analyzer

---

## 3. Code Structure

```
cookshop-mvp/
├── mobile/               # Flutter app (iOS, Android, Web)
├── frontend/             # Next.js web app (React/TypeScript)
├── services/             # Four Python Cloud Run services
│   ├── ai-analyzer/
│   ├── product-matcher/
│   ├── pubsub-worker/
│   └── state-manager/
├── infra/                # GCP setup scripts & service account
├── docs/                 # Documentation
├── .github/workflows/    # CI/CD pipelines
└── firebase.json         # Top-level Firebase config
```

### 3.1 Flutter App — `mobile/`

**Tech:** Flutter 3.x · Riverpod 2 · GoRouter · Dio · Firebase SDK

```
mobile/lib/
├── main.dart                    # App entry: Firebase init, FCM setup
├── app.dart                     # GoRouter routes + auth redirect
├── core/
│   ├── constants/
│   │   ├── api_constants.dart   # Cloud Run base URLs (env-overridable)
│   │   └── firestore_constants.dart  # Collection name constants
│   └── services/
│       ├── mlkit_detector_service.dart  # On-device real-time detection
│       └── gcp_vision_service.dart      # Remote GCP Vision fallback
├── data/
│   ├── models/                  # Freezed data classes (Product, UserProfile, etc.)
│   ├── repositories/            # Business logic interfaces (Auth, Session, ShoppingList)
│   └── sources/
│       ├── firebase/            # Firestore read/write
│       └── remote/              # HTTP clients: analyzer_api, matcher_api, session_api
├── domain/
│   └── usecases/                # Orchestration: analyze_image, tap_identify, video_analyze
└── presentation/
    ├── screens/                 # UI screens (main, live_scan, profile, admin, video_player)
    ├── providers/               # Riverpod providers (pipeline, auth, shopping_list, admin)
    └── widgets/                 # Reusable UI (product_card, object_glow_overlay, etc.)
```

**Key screens:**
| Screen | Purpose |
|--------|---------|
| `main_screen.dart` | Primary shopping UI, camera trigger |
| `live_scan_screen.dart` | Real-time on-device ML Kit object detection with glow overlay |
| `admin_screen.dart` | Admin panel — trigger analysis, manage sessions |
| `video_player_screen.dart` | HLS stream playback + real-time product sidebar |
| `profile_screen.dart` | User preferences (dietary, allergies, cuisines) |

**Pipeline state machine (`pipeline_provider.dart`):**
```
idle → analyzing → matching → saving → success
                                     ↘ error
```

**Base URLs** (`api_constants.dart`, overridable via `.env`):
```
ai-analyzer:       https://ai-analyzer-82592393149.us-central1.run.app
product-matcher:   https://product-matcher-82592393149.us-central1.run.app
state-manager:     https://state-manager-82592393149.us-central1.run.app
```

---

### 3.2 Next.js Web App — `frontend/`

**Tech:** Next.js 14 · React 18 · TypeScript · Firebase JS SDK · HLS.js

```
frontend/src/
├── app/
│   ├── page.tsx             # Main demo page: HLS stream + product sidebar
│   └── admin/page.tsx       # Admin dashboard
├── components/
│   ├── ShoppingList.tsx     # Firestore onSnapshot → real-time product list
│   ├── VideoPlayer.tsx      # HLS.js stream viewer
│   ├── admin/
│   │   ├── VideoAnnotator.tsx      # Frame-by-frame annotation tool
│   │   └── BoundingBoxCanvas.tsx   # Bounding box drawing UI
│   └── LoginPage / SignUpPage / ProfilePage
└── lib/
    ├── firebase.ts          # Firebase SDK init
    └── demoProfiles.ts      # Pre-seeded demo user profiles
```

**Environment vars** (`frontend/.env.local`):
```
NEXT_PUBLIC_FIREBASE_PROJECT_ID=        (cookshop-dev-prj-bd7e2 or cookshop-poc-prj)
NEXT_PUBLIC_ANALYZER_API_URL=           (Cloud Run URL or http://localhost:8081)
NEXT_PUBLIC_MATCHER_API_URL=
NEXT_PUBLIC_STATE_API_URL=
NEXT_PUBLIC_HLS_STREAM_URL=             gs://cookshop-poc-prj-hls-segments/live/playlist.m3u8
```

---

### 3.3 Backend Services — `services/`

All four services are **FastAPI + uvicorn** Python apps, containerized with Docker, deployed to Cloud Run.

#### ai-analyzer
Receives a GCS URI or image data, runs Vertex AI Gemini 2.0 Flash to identify objects, then Google Lens for visual product matching.

| Endpoint | Input | Output |
|----------|-------|--------|
| `POST /analyze` | `gcs_uri`, `transcript`, `ignore_terms` | `{items, products}` |
| `POST /identify` | `image_data` (base64), `query` | `{products}` (Lens only) |
| `GET/POST /config` | model name | active model |

**External deps:** Vertex AI (`google-cloud-aiplatform`), SerpAPI (Google Lens), ImgBB (image hosting)

#### product-matcher
Fuzzy-matches AI-detected item labels against a local product catalog JSON using `rapidfuzz`.

| Endpoint | Input | Output |
|----------|-------|--------|
| `POST /match` | `{items: string[]}` | `{matched_products, unmatched}` |

**Data:** `catalog.json` — ~20 mock grocery/kitchen products with price, image, purchase URL.

#### state-manager
Persists matched products into Firestore so clients get real-time updates via `onSnapshot`.

| Endpoint | Input | Output |
|----------|-------|--------|
| `POST /session/{id}/products` | `{products}` | `{status: "updated"}` |
| `GET /session/{id}` | — | current products |
| `DELETE /session/{id}` | — | cleared |

**Writes to:** `LiveShoppingSessions/{session_id}` in Firestore.

#### pubsub-worker
Entry point for the automated pipeline. Receives Pub/Sub push webhooks when a new HLS segment lands in Cloud Storage, then orchestrates the three services sequentially.

| Endpoint | Input | Output |
|----------|-------|--------|
| `POST /pubsub` | Pub/Sub push message (base64 JSON) | `200 OK` |

**Flow:** decode → extract `gs://` URI → `ai-analyzer /analyze` → `product-matcher /match` → `state-manager /session/products`

**Env vars:** `AI_ANALYZER_URL`, `PRODUCT_MATCHER_URL`, `STATE_MANAGER_URL`, `SESSION_ID`

---

## 4. Infrastructure

### GCP Services Used

| Service | Purpose |
|---------|---------|
| **Cloud Run** | Hosts all 4 backend services (serverless containers) |
| **Cloud Live Stream API** | Transcodes RTMP → HLS |
| **Cloud Storage** | Stores HLS segments (`.ts` + `.m3u8`) |
| **Pub/Sub** | Triggers pipeline on new GCS object finalize event |
| **Vertex AI** | Gemini 2.0 Flash for video/image analysis |
| **Artifact Registry** | Docker image storage per service |
| **Workload Identity Federation** | Keyless CI/CD auth from GitHub Actions |

### Firebase Services Used

| Service | Purpose |
|---------|---------|
| **Firebase Auth** | User sign-up / sign-in (email + password) |
| **Cloud Firestore** | Primary database + real-time sync to clients |
| **Firebase Hosting** | Serves Flutter web build (`build/web`) |

### Cloud Run Config (per service)
- Memory: `512Mi` · CPU: `1` · Min instances: `0` · Max instances: `10`
- Region: `us-central1`
- Auth: service-account based (no public unauthenticated invocations except pubsub webhook)

### Firestore Security Rules (simplified)
```
UserProfiles/{userId}     — owner read/write only
LiveShoppingSessions/{id} — public read, admin write
VideoAnnotations/{fileName} — authenticated read/write
VideoAnalysisCache/{fileName} — authenticated read/write
```

---

## 5. Data Model (Firestore)

### `UserProfiles/{userId}`
```
username, dob, profile_photo_url, gender
cooking_skill_level, preferred_meal_prep_time_minutes
allergies: string[], dietary_restrictions: string[]
spice_tolerance_level, favorite_cuisines: string[]
ignore_terms: string[]       ← fed into analyzer to filter noise
preference_terms: string[]   ← used by product_ranker for ranking
role: "user" | "admin"
```

### `LiveShoppingSessions/{sessionId}`
```
products: [
  { productId, name, price, imageUrl, purchaseUrl, seller, category }
]
```
Written by `state-manager`; read by Flutter and Next.js via `onSnapshot`.

### `VideoAnnotations/{fileName}`
```
status: string
annotations: [{ frameIndex, boundingBox, label, productId }]
videoDownloadUrl?: string
```
Written by admin annotation tool.

### `VideoAnalysisCache/{fileName}`
```
(cached AI analysis results, keyed by video filename)
```

---

## 6. How Everything Connects

### Live Stream Pipeline (Automated)

```
1. Creator streams via OBS → RTMP input endpoint (Cloud Live Stream API)
2. Cloud Live Stream transcodes → uploads HLS segments to Cloud Storage bucket
3. GCS fires "object finalized" event → Pub/Sub topic (video-segments-topic)
4. Pub/Sub pushes to pubsub-worker Cloud Run (POST /pubsub)
5. pubsub-worker extracts gs:// URI, calls ai-analyzer POST /analyze
6. ai-analyzer sends segment to Vertex AI Gemini 2.0 Flash → gets item list
7. ai-analyzer sends each item to Google Lens (via SerpAPI) → gets product images/URLs
8. pubsub-worker calls product-matcher POST /match with item labels
9. product-matcher fuzzy-matches against catalog.json → returns matched products
10. pubsub-worker calls state-manager POST /session/{id}/products
11. state-manager writes products to Firestore LiveShoppingSessions/{id}
12. Flutter/Next.js Firestore listener fires → UI updates product sidebar in real-time
```

### Manual Capture Pipeline (Flutter App)

```
1. User opens camera in Flutter app → taps on product or captures frame
2. Flutter calls analyze_image_usecase.dart
3. Use case calls analyzer_api.dart → POST /analyze (image_data) on ai-analyzer
4. Use case calls matcher_api.dart → POST /match on product-matcher
5. Use case calls session_api.dart → POST /session/{id}/products on state-manager
6. Firestore listener updates shopping list in the same Flutter session
```

### On-Device Detection (ML Kit, no backend)

```
1. User opens live_scan_screen.dart
2. mlkit_detector_service.dart runs Google ML Kit object detection on device
3. Detected objects shown with glow overlay (object_glow_overlay.dart)
4. User taps a detected object → tap_identify_usecase.dart
5. Cropped image sent to ai-analyzer POST /identify (Lens only, skip Gemini)
6. Matched product displayed immediately
```

### Admin Annotation Flow

```
1. Admin uploads a video via admin_screen or admin Next.js page
2. Video stored in Firebase Storage
3. VideoAnnotator.tsx allows frame-by-frame bounding box drawing
4. Annotations saved to Firestore VideoAnnotations/{fileName}
5. (Future: admin curates video → Cloud Run endpoint → CuratedVideoMatches collection)
```

### Real-Time Product Sync

```
Firestore LiveShoppingSessions/{sessionId}
      ├── Flutter: cloud_firestore onSnapshot → ShoppingListProvider → ShoppingList widget
      └── Next.js: Firebase JS SDK onSnapshot → ShoppingList.tsx component
```

Both clients use the same Firestore document — they share the same live product state.

---

## 7. CI/CD Pipeline

### `ci.yml` — Build & Validate
- **Triggers:** PRs and pushes to `develop`, `main`, `feature/**`, `release/**`
- **Frontend:** `npm ci → lint → build`
- **Services:** Validate all 4 Dockerfiles build successfully

### `deploy-cloudrun.yml` — Backend Services
- **Triggers:** push to `develop` (→ dev) or `main`/`release/**` (→ prod)
- **Steps:**
  1. Auth via Workload Identity Federation
  2. Build Docker images for all 4 services
  3. Push to Artifact Registry (`us-central1-docker.pkg.dev/{project}/services/{name}`)
  4. Deploy each image to Cloud Run (`gcloud run deploy`)
  5. Update Pub/Sub push subscription URL with new pubsub-worker URL

### `deploy-firebase.yml` — Flutter Web / Next.js
- **Triggers:** push to `develop` → dev live channel; `main`/`release/**` → prod live channel; `feature/**` / PRs → dev preview channel (7-day TTL, posts URL as PR comment)
- **Steps:**
  1. Auth via Workload Identity Federation
  2. `flutter pub get && flutter build web --release` → outputs to `mobile/build/web/`
  3. `firebase deploy --only hosting` against the appropriate project alias

---

## 8. Authentication & Authorization

**Provider:** Firebase Authentication (Email + Password)

**User roles** (stored in `UserProfiles/{userId}.role`):
- `user` — can read/write own profile, read live sessions, add to shopping list
- `admin` — can access admin screens, write annotations, trigger analysis

**Client-side guard:** `app.dart` GoRouter redirects unauthenticated users to `/login`.

**Firestore rules** enforce server-side: users can only write their own profile; only admins (or the state-manager service account) can write session data.

**Backend auth:** Cloud Run services are called by:
- `pubsub-worker` (internal service-to-service, same GCP project)
- Flutter/Next.js clients (direct REST calls from authenticated sessions — CORS enabled on all services)

---

## Quick Reference: Key URLs & IDs

| Resource | Dev | Prod |
|----------|-----|------|
| Firebase Project | `cookshop-dev-prj-bd7e2` | `cookshop-poc-prj` |
| Firebase Hosting | `cookshop-dev-prj-bd7e2.web.app` | `cookshop-poc-prj.web.app` |
| Cloud Run URL pattern | `https://{service}-{hash}-uc.a.run.app` | same pattern |
| ai-analyzer (prod) | — | `https://ai-analyzer-82592393149.us-central1.run.app` |
| product-matcher (prod) | — | `https://product-matcher-82592393149.us-central1.run.app` |
| state-manager (prod) | — | `https://state-manager-82592393149.us-central1.run.app` |
| HLS Stream | — | `gs://cookshop-poc-prj-hls-segments/live/playlist.m3u8` |
| Firestore session ID | `live-session-001` (configurable) | `live-session-001` |
