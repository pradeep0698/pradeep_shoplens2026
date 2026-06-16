# CookShop — Project Overview

**AI-Powered Live Cooking Video Analysis and Real-Time Shopping Platform**

---

## What This Is

CookShop is a Google Cloud-native, event-driven platform that turns a live cooking stream into a real-time shoppable experience. As a chef cooks on stream, the system analyzes the video using Gemini AI, detects ingredients and utensils, matches them to a product catalog, and automatically updates a viewer-facing shopping list — without any human tagging or manual curation.

**Core flow:** Camera → RTMP → Live Stream API → GCS → Pub/Sub → AI analysis → Product matching → Firestore → Browser

---

## Business Value

| Pillar | Value |
|--------|-------|
| **Revenue Enablement** | Shoppable moments turn passive cooking content into direct revenue via affiliate links, sponsored products, and grocery integrations |
| **Customer Experience** | Frictionless path from watching to buying; shopping list updates every few seconds without page refresh |
| **Strategic Intelligence** | Analytics-ready data on recipe trends, product popularity, brand performance, and shopper interest |
| **Scalability** | Fully managed GCP services handle live traffic bursts with no infrastructure to maintain |

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | Next.js 14 (TypeScript + Tailwind CSS), hosted on Firebase Hosting |
| **Real-time updates** | Firestore `onSnapshot` listener (no WebSocket server needed) |
| **Video player** | hls.js in low-latency mode |
| **Backend services** | FastAPI (Python) microservices on Cloud Run |
| **AI / ML** | Vertex AI Gemini 2.0 Flash (multimodal), Cloud Speech-to-Text, Cloud Vision AI |
| **Video ingestion** | Google Cloud Live Stream API (RTMP in, HLS out) |
| **Eventing** | Cloud Pub/Sub (GCS notifications → push subscription) |
| **State storage** | Firestore (Native mode) — live session state |
| **Media storage** | Cloud Storage — HLS segments, manifests |
| **Fuzzy matching** | rapidfuzz (Python) |

Production additions (Phase 2): Media CDN, Eventarc, Cloud Workflows, Cloud SQL, BigQuery, Cloud Monitoring, Cloud Build, Artifact Registry.

---

## Provisioned GCP Services

Services currently enabled in project **cookshop-poc**, ranked by criticality to the application:

| Rank | Service | Role in CookShop |
|------|---------|-----------------|
| 1 | **Cloud Run** | Hosts the four core microservices: `ai-analyzer`, `product-matcher`, `pubsub-worker`, `state-manager` |
| 2 | **Cloud Firestore** | Primary NoSQL store for live session state; drives real-time UI updates via `onSnapshot` |
| 3 | **Cloud Pub/Sub** | Async event bus — `video-segments-topic` triggers the analysis pipeline on each new HLS segment |
| 4 | **Vertex AI (Agent Platform)** | Gemini 2.0 Flash multimodal API for ingredient/utensil detection and structured JSON extraction |
| 5 | **Artifact Registry** | Stores container images built and deployed to Cloud Run |
| 6 | **BigQuery** | Large-scale analytics on recipe trends, product popularity, and shopper interest (Phase 2 active) |
| 7 | **Cloud Storage** | HLS segment and manifest storage; source of GCS Object Finalize notifications to Pub/Sub |
| 8 | **Cloud Build** | CI/CD pipeline — automated build → push → deploy for each microservice (Phase 2 active) |
| 9 | **Cloud Logging & Monitoring** | Observability across all services; health tracking during live broadcast windows (Phase 2 active) |

---

## Architecture (MVP)

```
[Camera / OBS]
      |  RTMP
      ▼
[Cloud Live Stream API]
      |  HLS segments (.ts files)
      ▼
[Cloud Storage — gs://cookshop-poc-hls-segments]
      |  GCS Object Finalize notification
      ▼
[Pub/Sub — video-segments-topic]
      |  Push subscription
      ▼
[pubsub-worker — Cloud Run]
      |  HTTP
      ├──▶ [ai-analyzer — Cloud Run]  →  Vertex AI Gemini 2.0 Flash
      |         returns: ["Tomato", "Chef's Knife", ...]
      ├──▶ [product-matcher — Cloud Run]  →  catalog.json + rapidfuzz
      |         returns: [{product_id, name, price, image_url}, ...]
      └──▶ [state-manager — Cloud Run]  →  Firestore LiveShoppingSessions
                                               |
                                               | onSnapshot
                                               ▼
                                      [Browser — cookshop-poc.web.app]
                                        Video player + Shopping list sidebar
```

---

## Phase 1: MVP / Demo Scope

Validates the core loop — live video → AI detection → product list → live UI — with minimal operational overhead.

- **Ingestion:** Live Stream API (RTMP → HLS → GCS)
- **Eventing:** Pub/Sub push subscription triggers pubsub-worker
- **AI Analysis:** Vertex AI Gemini 2.0 Flash analyzes each HLS segment; returns structured JSON
- **Product Matching:** Fuzzy match against a static 20-item catalog
- **State:** Firestore stores current shopping session; frontend listens with `onSnapshot`
- **Frontend:** Next.js hosted on Firebase Hosting; two-panel layout with HLS.js player

**Out of scope for demo:** authentication, cart/checkout, multi-user sync, real retailer API integrations.

See [PROGRESS.md](PROGRESS.md) for detailed task status and the two remaining steps to demo readiness.

---

## Phase 2: Production Scale

Builds on the MVP to support real users, real product catalogs, and enterprise reliability.

| Area | Additions |
|------|-----------|
| **Delivery** | Media CDN for low-latency video at scale; Cloud Storage for recordings/replay |
| **Orchestration** | Eventarc + Cloud Workflows replace direct HTTP chaining |
| **AI Accuracy** | Cloud Vision OCR for on-screen text; enhanced Gemini prompts for quantities + confidence |
| **Product Discovery** | Google Shopping API, Programmable Search, Instacart/Kroger APIs; dynamic catalog |
| **Commerce** | Sponsored products, affiliate links, direct-to-cart integrations |
| **Data Layer** | Cloud SQL (users, streams, carts, history), BigQuery ✓ already provisioned (analytics + trend reports), PDF/CSV export |
| **Security** | All API creds in Secret Manager; Security Command Center; VPC Service Controls |
| **Observability** | Cloud Logging + Monitoring ✓ already provisioned + Error Reporting; SLOs for live broadcast windows |
| **CI/CD** | Cloud Build ✓ already provisioned + Artifact Registry ✓ already provisioned; automated build → test → deploy per service |
