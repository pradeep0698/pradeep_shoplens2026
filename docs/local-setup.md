# Local Setup — for a New Developer

This is the actual, verified-working state of the `shoplens-dev-499700` dev environment as of 2026-06-18 (see [docs/status/2026-06-18.md](status/2026-06-18.md) for how it got there). If anything here conflicts with `README.md`, trust this file — the README has some stale/aspirational claims (e.g. it references a `deploy-cloudrun.yml` GitHub Actions workflow that doesn't exist in this repo).

## 1. Prerequisites

Install these before doing anything else:

- **Git**
- **Node.js 18+** and npm — for the frontend
- **Python 3.11+** — for the backend services (only needed if you'll run them locally; not needed just to run the frontend/mobile app)
- **Flutter SDK** + Dart — for the mobile app
- **Google Cloud CLI** (`gcloud`) — only needed if you'll deploy or inspect GCP resources
- **Firebase CLI**: `npm install -g firebase-tools`
- **`flutterfire_cli`** (only needed if you ever have to regenerate `mobile/lib/firebase_options.dart`): `dart pub global activate flutterfire_cli`

## 2. Clone the repo

```bash
git clone https://github.com/shoplensai-coder/shoplens.git
cd shoplens
```

The repo is private — if `git clone` prompts for a password and rejects it, GitHub no longer accepts account passwords over HTTPS. Use `gh auth login` (GitHub CLI, browser-based device code flow) instead, then retry the clone.

## 3. Decide which path you need

**Path A — just run the frontend/mobile app, pointing at the already-deployed dev backend.** This is the common case and needs no GCP/Firebase account access at all — just a handful of config files (Section 4).

**Path B — also run/modify the backend services, or touch GCP/Firebase infra directly.** You'll additionally need to be granted access to the `shoplens-dev-499700` GCP project and its Firebase project. Ask the project owner (`shoplens.ai@gmail.com`) to add your Google account with at least `Viewer` (or `Editor`/`Owner` if you need to deploy) via **IAM & Admin → IAM** in the GCP Console, and as a collaborator in Firebase Console → Project Settings → Users and permissions.

## 4. Config files you need (none of these are committed to git)

These are all gitignored on purpose — get the real values from whoever already has them (the project owner keeps a master copy in a local-only file called `github-secrets-dev` at the repo root, which is never pushed). Ask them to share the values with you over a secure channel (Slack DM, 1Password, etc.) — **not** by emailing/committing them.

| File | Template to copy from | What it needs |
|---|---|---|
| `frontend/.env.local` | `frontend/.env.local.example` | Firebase web config (`apiKey`, `messagingSenderId`, `appId`), session ID, the 3 Cloud Run service URLs, HLS stream URL |
| `mobile/.env` | `mobile/.env.example` | The 3 Cloud Run service URLs |
| `mobile/android/app/google-services.json` | — (binary-ish JSON, no template) | Real Firebase Android app config — get this file directly from the project owner, or if you have Firebase project access, regenerate it yourself (Section 6) |
| `mobile/ios/Runner/GoogleService-Info.plist` | — | Same as above, for iOS |

Backend services (`services/*/.env.example`) are only needed if you're running those services locally (Path B) — copy each to `.env` and fill in `SERPAPI_KEY` (ask the project owner for the current key) and `PROJECT_ID=shoplens-dev-499700`.

## 5. Run the frontend

```bash
cd frontend
npm install
npm run dev
```

Opens at `http://localhost:3000`. It talks directly to the deployed dev Cloud Run services and Firestore — no local backend needed.

## 6. Run the mobile app

```bash
cd mobile
flutter pub get
flutter run
```

`lib/firebase_options.dart` is committed to git and `lib/main.dart` imports it directly with no
fallback — do not add it to `.gitignore`. Its hardcoded values are Firebase client config, not
secrets (Firebase security is enforced by Firestore/Auth rules, not by hiding these), and every
value is overridable at compile time via `--dart-define-from-file` per environment (see
`docs/shoplens2026-dev-setup.md` Section 14). Gitignoring it broke fresh checkouts once already
(2026-07-03) — `flutter build apk` fails immediately with "Error when reading
'lib/firebase_options.dart'" since there's no generated fallback.

If you ever need to regenerate `lib/firebase_options.dart` or the platform config files yourself (e.g. you have your own Firebase project access and the existing files are missing or stale), run from `mobile/`:

```bash
firebase login
flutterfire configure --project=shoplens-dev-499700 --platforms=android,ios --android-package-name=com.shoplens.app --ios-bundle-id=com.shoplens.app
```

Known issue (hit during initial setup): on Windows, `flutterfire configure` sometimes registers the iOS app in Firebase but fails to write `GoogleService-Info.plist` locally. If that happens, pull it directly instead:

```bash
firebase apps:sdkconfig ios <ios-app-id> --project=shoplens-dev-499700
```

(get `<ios-app-id>` from `firebase apps:list --project=shoplens-dev-499700`) and save the output to `mobile/ios/Runner/GoogleService-Info.plist`.

## 7. Run the backend services locally (optional — Path B only)

Each service is a small FastAPI app. In separate terminals, from the repo root:

```bash
cd services/ai-analyzer && pip install -r requirements.txt && uvicorn main:app --reload --port 8081
cd services/product-matcher && pip install -r requirements.txt && uvicorn main:app --reload --port 8082
cd services/state-manager && pip install -r requirements.txt && uvicorn main:app --reload --port 8083
cd services/pubsub-worker && pip install -r requirements.txt && uvicorn main:app --reload --port 8080
```

If you want `frontend/.env.local` / `mobile/.env` to point at your local services instead of the deployed dev ones, swap in `http://localhost:8081` / `:8082` / `:8083` for the analyzer/matcher/state URLs.

To actually call Firestore/Pub/Sub/Vertex AI from your local machine, you need application default credentials for an account with access to `shoplens-dev-499700`:

```bash
gcloud auth application-default login
gcloud config set project shoplens-dev-499700
```

## 8. Current real values (non-secret — safe to reference here)

| Thing | Value |
|---|---|
| GCP/Firebase project | `shoplens-dev-499700` (project number `935092313069`) |
| Region | `us-central1` |
| `ai-analyzer` URL | `https://ai-analyzer-935092313069.us-central1.run.app` |
| `product-matcher` URL | `https://product-matcher-935092313069.us-central1.run.app` |
| `state-manager` URL | `https://state-manager-935092313069.us-central1.run.app` |
| `pubsub-worker` URL | `https://pubsub-worker-935092313069.us-central1.run.app` (not publicly callable — only the Pub/Sub push subscription can invoke it) |
| Session ID | `live-session-001` |
| HLS bucket | `gs://shoplens-dev-hls-segments` |
| Lens temp-image bucket | `gs://shoplens-dev-lens-tmp` |
| Pub/Sub topic / subscription | `video-segments-topic` / `video-segments-sub` |

Actual API keys, the SerpApi key, and the Firebase config values are **not** listed here on purpose — get those from the project owner as described in Section 4.

## 9. Known gaps (don't be surprised by these)

- There is no GitHub Actions CI/CD yet (`.github/workflows/` is empty). All deploys so far were manual `gcloud run deploy --source .` commands run from Cloud Shell. `README.md` describes a CI/CD setup that hasn't actually been built.
- The live RTMP → HLS → Pub/Sub → Gemini pipeline is wired end-to-end for push delivery, but the Cloud Live Stream channel itself (Part 5 of [docs/shop-lens-cloud-setup.md](shop-lens-cloud-setup.md)) hasn't been set up yet, so there's no live video source yet — only the on-demand "Analyze" path (browser → `ai-analyzer` → `product-matcher` → `state-manager`) is confirmed working.
