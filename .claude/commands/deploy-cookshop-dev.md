Deploy cloud services and frontend to cookshop-dev (Rajan prod).

**cookshop-dev is the stable platform** — released once per week, not on every change. Active development happens against `shoplens2026-dev` (see `deploy-dev.md`); only deploy here when it's actually time for the weekly release, not for routine iteration.

Run `bash scripts/deploy-cookshop-dev.sh` from the repo root to deploy.

## What this does

- Auto-detects which services changed since the last deploy using the saved git SHA in `.cookshop-dev-last-deploy`
- Deploys only changed services to Cloud Run (project: `cookshop-dev-prj`, region: `us-central1`)
- Deploys frontend if `frontend/` changed (Firebase Hosting → `cookshop-dev-prj-bd7e2`)
- Saves current SHA after a successful deploy so the next run is incremental

## Services covered

- `ai-analyzer` — image analysis (Gemini + Google Lens)
- `product-matcher` — Google Shopping search (SerpAPI)
- `state-manager` — Firestore session state
- `voice-assistant` — Gemini Live voice sessions

`live-ingest` and `pubsub-worker` are NOT deployed to cookshop-dev (live video pipeline not used here).

## Usage options

```bash
bash scripts/deploy-cookshop-dev.sh                         # auto-detect changed services
bash scripts/deploy-cookshop-dev.sh --all                   # force-deploy everything
bash scripts/deploy-cookshop-dev.sh ai-analyzer             # specific service(s) only
bash scripts/deploy-cookshop-dev.sh --frontend              # frontend only
```

## Steps

1. Run the deploy script and stream its output so the user can see progress
2. After all Cloud Run deploys complete, health-check all 4 services:
   - `https://ai-analyzer-82592393149.us-central1.run.app/health`
   - `https://product-matcher-82592393149.us-central1.run.app/health`
   - `https://state-manager-82592393149.us-central1.run.app/health`
   - `https://voice-assistant-82592393149.us-central1.run.app/health`
3. Report a summary table: service name, HTTP status, health response body
4. If any service returns non-200, show the body and flag it
5. Remind the user about mobile (APK) if `mobile/` changed:
   ```
   cd mobile && bash scripts/build-cookshop-dev-apk.sh
   ```
   And iOS: trigger Codemagic build manually from UI (firebase-cookshop var group)

## Known issues to watch for

- **Firebase deploy needs the right account**: `shoplens.ai@gmail.com` does NOT have access to `cookshop-dev-prj-bd7e2`. The user needs to run `firebase login:add` with the account that owns that project before frontend deploy works.
- **FastAPI version**: All services use `fastapi==0.138.1`. If a service fails to start with `HealthCheckContainerError`, check `requirements.txt` — using `pydantic.Field()` for GET query params crashes on startup with newer FastAPI; use `fastapi.Query()` instead.
