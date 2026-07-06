Deploy cloud services and frontend to shoplens2026-dev.

**shoplens2026-dev is the active development environment** — deploy here freely as changes land. It's separate from `cookshop-dev` (Rajan's prod), which is the stable platform released only once per week (see `deploy-cookshop-dev.md`).

Run `bash scripts/deploy-shoplens2026-dev.sh` from the repo root to deploy.

This is a separate mechanism from `.github/workflows/deploy-shoplens2026-dev.yml`
(the GitHub Actions workflow, which pulls env vars from GitHub Secrets via
Workload Identity Federation). This script deploys directly from a local
checkout via `gcloud run deploy --source`, using the `.env.shoplens2026-dev`
vault files already committed per service — no GitHub Actions access needed.
Use this when working from a local session; use the GH Actions workflow when
you specifically want the Secrets-managed CI path (and have `gh` access to
`shoplens2026ai/shoplens2026` — see Known issues below).

## What this does

- Auto-detects which services changed since the last deploy using the saved git SHA in `.shoplens2026-dev-last-deploy`
- Deploys only changed services to Cloud Run (project: `project-b1a5dd5a-69e6-4db3-9d7`, region: `us-central1`)
- Deploys frontend if `frontend/` changed (Firebase Hosting → `project-b1a5dd5a-69e6-4db3-9d7`, display name "shoplens2026-dev")
- Saves current SHA after a successful deploy so the next run is incremental

## Services covered

- `ai-analyzer` — image analysis (Gemini + Google Lens)
- `product-matcher` — Google Shopping search (SerpAPI)
- `state-manager` — Firestore session state
- `voice-assistant` — Gemini Live voice sessions
- `pubsub-worker` — live video segment processing (deployed here, unlike cookshop-dev)

`live-ingest` is NOT deployed to shoplens2026-dev (no `.env.shoplens2026-dev` file, no Cloud Run service for it in this project).

## Usage options

```bash
bash scripts/deploy-shoplens2026-dev.sh                         # auto-detect changed services
bash scripts/deploy-shoplens2026-dev.sh --all                   # force-deploy everything
bash scripts/deploy-shoplens2026-dev.sh ai-analyzer              # specific service(s) only
bash scripts/deploy-shoplens2026-dev.sh --frontend               # frontend only
```

## Steps

1. Run the deploy script and stream its output so the user can see progress
2. After all Cloud Run deploys complete, health-check all 5 services:
   - `https://ai-analyzer-es3gcms2pa-uc.a.run.app/health`
   - `https://product-matcher-es3gcms2pa-uc.a.run.app/health`
   - `https://state-manager-es3gcms2pa-uc.a.run.app/health`
   - `https://voice-assistant-es3gcms2pa-uc.a.run.app/health`
   - `https://pubsub-worker-es3gcms2pa-uc.a.run.app/health`

   (Cloud Run URLs can be re-derived if they ever change: `gcloud run services list --project=project-b1a5dd5a-69e6-4db3-9d7 --region=us-central1 --format="table(metadata.name,status.url)"`.)
3. Report a summary table: service name, HTTP status, health response body
4. If any service returns non-200, show the body and flag it

## Known issues to watch for

- **Two separate deploy paths, two separate trust models.** This script deploys with whatever's in the local `.env.shoplens2026-dev` files using the operator's own `gcloud`/`firebase` credentials (owner-level access confirmed 2026-07-04). The GitHub Actions workflow instead deploys via Workload Identity Federation using secrets stored in GitHub (`SHOPLENS2026DEV_*_ENV`). If both paths are used interchangeably, the two env-var sources can drift — if you edit env vars, update both the local `.env.shoplens2026-dev` file and the matching GitHub Secret, or pick one path as the source of truth for this project.
- **`gh` CLI currently has no access to `shoplens2026ai/shoplens2026`.** As of 2026-07-04, `gh api repos/shoplens2026ai/shoplens2026` 404s under the active `GITHUB_TOKEN`-based auth in this environment — the GitHub Actions workflow can't be triggered or inspected via `gh` until that's fixed (different token/account with repo access, or grant the existing token access). Not a blocker for this script, which never calls `gh`.
- **No shoplens2026-dev-specific mobile APK build script exists** (unlike `mobile/scripts/build-cookshop-dev-apk.sh` for cookshop-dev). If `mobile/` changed and a build against this environment is needed, that script would need to be created or the existing one adapted — don't assume one exists.
- **FastAPI version**: services use `fastapi==0.138.1`. If a service fails to start with `HealthCheckContainerError`, check `requirements.txt` — using `pydantic.Field()` for GET query params crashes on startup with newer FastAPI; use `fastapi.Query()` instead. (Same known issue as cookshop-dev.)
