# Analyze API performance testing — Postman collection

Fixed-input performance harness for `services/ai-analyzer`'s `POST /analyze`
endpoint. The goal: run the *exact same request* before and after each
performance change so timing differences are caused by the code, not by a
different image, prompt, or network condition.

## Files

- `shoplens-analyze-perf.postman_collection.json` — the collection. Has two requests:
  - **0. Check Current Model** — `GET /config`, records the active `GEMINI_MODEL` so it ends up in the run summary.
  - **1. Analyze - Fixed Test Image** — `POST /analyze` with the fixed test image embedded as a collection variable (`image_base64`), so every run sends byte-identical input.
- `shoplens-local.postman_environment.json` — `baseUrl = http://localhost:8080`. Duplicate this file (or add a variable) if you also want to point at a deployed Cloud Run URL.
- `_generate_collection.py` — regenerates the collection. Run this if you change the fixed test image; it base64-encodes the image and writes the full collection file so the (large) image payload never has to be hand-edited.

## Fixed test image

`C:\ShopLens\images\image-1.webp`, embedded as the `image_base64` collection
variable. To swap the test image, edit `IMAGE_PATH` in `_generate_collection.py`
and re-run it.

## How to run a measurement

1. Start `services/ai-analyzer` locally (`uvicorn main:app --host 0.0.0.0 --port 8080`), with whatever code change you're measuring already applied.
2. Import both JSON files into Postman, select the **ShopLens - Local ai-analyzer** environment.
3. Open **View > Show Postman Console** (so you can see the logged summary line).
4. Run **0. Check Current Model**, then **1. Analyze - Fixed Test Image**.
5. Read the result from two places:
   - The response pane's **Time** field (top right) — total wall-clock time for the `/analyze` call.
   - The Postman Console line starting `[ANALYZE PERF] model=... time_ms=... items=... products=... warnings=... request_id=...`.
6. Record the run in [`docs/analyze-perf-test-results.md`](../docs/analyze-perf-test-results.md) — one row per run, with the change under test.
7. Make your next change, restart the service, repeat from step 4.

## Notes on noise

A single request's timing is noisy (cold start, JIT warmup, GC pauses,
upstream API latency). For a real before/after comparison, run **1. Analyze**
3-5 times back to back for each variant and compare medians, not single
samples — Postman's Collection Runner (Run button on the collection,
set Iterations) can do this without manual re-clicking.

## Optional: scripted repeats with Newman

If you have Newman installed (`npm install -g newman`), you can run N
iterations from the CLI and get a summary without manually clicking:

```sh
newman run shoplens-analyze-perf.postman_collection.json \
  -e shoplens-local.postman_environment.json \
  -n 5 --reporters cli
```
