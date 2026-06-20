# ShopLens — Dev Platform: URLs, Logins & Services Summary

_Compiled 2026-06-18 from `docs/local-setup.md`, `README.md`, `docs/status/2026-06-18.md`, `.firebaserc`, and `.env.example` files. `docs/local-setup.md` is the most current/trustworthy source. No actual passwords or API keys are stored in this repo (they are gitignored, kept in a local-only `github-secrets-dev` file with the project owner)._

## GitHub

| Item | Value |
|---|---|
| Repo | https://github.com/shoplensai-coder/shoplens (private) |
| Org | `shoplensai-coder` |
| Auth | Password auth over HTTPS is rejected — use `gh auth login` (browser device-code flow) |
| Environments/CI | No `.github/workflows/` exists yet — all deploys are manual `gcloud`/`firebase` CLI |

## Google Cloud / Firebase

| Item | Value |
|---|---|
| Current GCP project | `shoplens-dev-499700` (project number `935092313069`) |
| Region | `us-central1` |
| Project owner (ask for access) | `shoplens.ai@gmail.com` — grants IAM in GCP Console + Firebase Console collaborator access |
| Firebase Console | https://console.firebase.google.com → project `shoplens-dev-499700` |
| Runtime service account | `shoplens-runner@shoplens-dev-499700.iam.gserviceaccount.com` |
| Firebase Auth domain | `shoplens-dev-499700.firebaseapp.com` |
| Storage bucket (Firebase) | `shoplens-dev-499700.firebasestorage.app` |

**Note:** Two abandoned earlier projects exist — `shoplens-dev-prj` and `shoplens-dev-prj-ccf98` — superseded by `shoplens-dev-499700` on 2026-06-18. Don't use them.

## Cloud Run Service URLs (current, `shoplens-dev-499700`)

| Service | URL | Public? |
|---|---|---|
| ai-analyzer | https://ai-analyzer-935092313069.us-central1.run.app | Yes |
| product-matcher | https://product-matcher-935092313069.us-central1.run.app | Yes |
| state-manager | https://state-manager-935092313069.us-central1.run.app | Yes |
| pubsub-worker | https://pubsub-worker-935092313069.us-central1.run.app | No — only Pub/Sub push subscription can call it |

**Note:** `infra/infra_status.txt` is stale — it lists the same service names under project number `1017419148960`, "last verified 2026-05-04", deployed by `aistreamscan@gmail.com`. That's an older/different project, not the current one. Consider deleting or updating that file so it doesn't get confused with the URLs above.

## Storage / Pub/Sub

| Item | Value |
|---|---|
| HLS bucket | `gs://shoplens-dev-hls-segments` (public read) |
| Lens temp-image bucket | `gs://shoplens-dev-lens-tmp` (public read, 1-day lifecycle) |
| Pub/Sub topic | `video-segments-topic` |
| Pub/Sub subscription | `video-segments-sub` (push → pubsub-worker) |
| Firestore | Native mode, `LiveShoppingSessions/{session_id}` doc |

## Other / Third-party

| Item | Value |
|---|---|
| SerpApi | Key was leaked in `services/product-matcher/.env.example`, scrubbed from git history, rotated. Current key lives only in `github-secrets-dev`, not in the repo. Force-push to scrub GitHub history is still pending per the 2026-06-18 status notes. |
| Local dev frontend | http://localhost:3000 |
| Local backend ports | ai-analyzer `:8081`, product-matcher `:8082`, state-manager `:8083`, pubsub-worker `:8080` |

No actual usernames/passwords/API keys exist anywhere in this repo by design — for real credential values, contact `shoplens.ai@gmail.com` for the `github-secrets-dev` file contents.
