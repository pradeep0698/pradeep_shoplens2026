Run the ShopLens Postman collections with Newman and generate HTML test reports.

Run `bash scripts/run-postman-tests.sh` from the repo root.

## What this does

- Runs `docs/postman/shoplens-all-services.postman_collection.json` (health, AI Analyzer, Product Matcher, State Manager, Voice Assistant, Pub/Sub Worker, plus the `_Flows` end-to-end scenarios) against a chosen Postman environment.
- Optionally also runs `postman/shoplens-analyze-perf.postman_collection.json` (ai-analyzer latency benchmark — calls real Gemini, takes ~40s+).
- Writes an HTML report (via `newman-reporter-htmlextra`) to `docs/postman/test-results/<yyyy-mm-dd-hh-mm>-<suite>.html` for each suite run.
- Installs `newman-reporter-htmlextra` globally on first use if it's missing. Requires `newman` to already be installed globally (`npm install -g newman`).

## Usage options

```bash
bash scripts/run-postman-tests.sh                        # main collection vs cookshop-dev-rajan-prod (default, the live env)
bash scripts/run-postman-tests.sh shoplens-dev            # main collection vs shoplens-dev instead
bash scripts/run-postman-tests.sh --with-perf             # main collection + the ai-analyzer perf collection
bash scripts/run-postman-tests.sh --perf-only             # only the perf collection
```

## Steps

1. Run the script and stream its output so the user can see live pass/fail per request.
2. After it finishes, report per suite: total requests, total assertions, pass/fail counts, and the path(s) to the generated HTML report(s).
3. For any failing assertion, quote the failure detail from the CLI output (request name, expected vs actual status) and say whether it's a **known/expected** failure or a **new regression**:
   - `Voice Assistant / Start Voice Session|Send Session Event|Finalize Voice Session` returning `401` is expected unless the `firebase_token` collection variable was set to a real Firebase ID token — not a bug.
   - `GET /thumbnail` returning `502` is expected if `test_thumbnail_url` is still the placeholder value — not a bug. Grab a real thumbnail URL from a `/match` or `/search` response's `image_url` field and set that collection variable to test it for real.
   - Anything else failing (a service `/health` check, `/analyze`, `/match`, `/session`, `/pubsub`, etc.) is a real regression — investigate before reporting done.
4. Don't open or paste the full HTML report into the conversation — just point to its path. The user can open it in a browser.

## Known issues to watch for

- `shoplens-dev`'s `pubsub-worker` requires an authenticated Cloud Run invoker (returns `403 Forbidden` from Google's frontend, not the app) — it's not in the main collection's reachable set for that environment by design. `cookshop-dev-rajan-prod`'s `pubsub-worker` is public and testable.
- The perf collection always hits `postman/shoplens-dev-cloud.postman_environment.json` (ai-analyzer only) — it's not parameterized by environment name like the main suite.
- If `newman-reporter-htmlextra` install fails (no network), fall back to `--reporters cli` only and tell the user no HTML report was produced.
