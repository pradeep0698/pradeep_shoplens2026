# Analyze API performance testing — Postman collection

Fixed-input performance harness for `services/ai-analyzer`'s `POST /analyze`
and `POST /identify` endpoints. The goal: run the *exact same request*
before and after each performance change so timing differences are caused
by the code, not by a different image, prompt, or network condition.

## Files

- `shoplens-analyze-perf.postman_collection.json` — the collection. Has three requests:
  - **0. Check Current Model** — `GET /config`, records the active `GEMINI_MODEL` so it ends up in the run summary.
  - **1. Analyze - Fixed Test Image** — `POST /analyze` with the fixed test image embedded as a collection variable (`image_base64`), so every run sends byte-identical input.
  - **2. Identify - Fixed Crop** — `POST /identify` (tap-to-identify path: Gemini description → GCS → Google Lens, skips Gemini's multi-object detection) with a fixed crop embedded as `identify_crop_base64` — a deterministic crop of the fixed test image (the dress, excluding the face).
- `shoplens-local.postman_environment.json` — `baseUrl = http://localhost:8080`. `shoplens-dev-cloud.postman_environment.json` points at the deployed Cloud Run dev URL instead (used when local ADC credentials aren't available).
- `_generate_collection.py` — regenerates the collection. Run this if you change the fixed test image or the identify crop region; it base64-encodes both and writes the full collection file so the (large) payloads never have to be hand-edited.

## Fixed test inputs

- **Analyze**: `C:\ShopLens\images\image-1.webp`, embedded as `image_base64`. To swap it, edit `IMAGE_PATH` in `_generate_collection.py` and re-run it.
- **Identify**: a crop of the same image, region controlled by `IDENTIFY_CROP_BOX_FRACTIONS` in `_generate_collection.py` (fractions of width/height — deterministic, so re-running the generator always produces the identical crop).

## How to run a measurement

1. Start `services/ai-analyzer` locally (`uvicorn main:app --host 0.0.0.0 --port 8080`), with whatever code change you're measuring already applied. (Or deploy to the Cloud Run dev service and use the `shoplens-dev-cloud` environment if you don't have local ADC credentials.)
2. Import both JSON files into Postman, select the matching environment.
3. Open **View > Show Postman Console** (so you can see the logged summary line).
4. Run **0. Check Current Model**, then **1. Analyze - Fixed Test Image** and/or **2. Identify - Fixed Crop**.
5. Read the result from two places:
   - The response pane's **Time** field (top right) — total wall-clock time for the call.
   - The Postman Console line starting `[ANALYZE PERF] ...` or `[IDENTIFY PERF] ...`.
6. Record the run in [`docs/analyze-perf-test-results.md`](../docs/analyze-perf-test-results.md) — one row per run, with the change under test.
7. Make your next change, restart/redeploy the service, repeat from step 4.

## Notes on noise

A single request's timing is noisy (cold start, JIT warmup, GC pauses,
upstream API latency). For a real before/after comparison, run the request
you're measuring 3-5 times back to back for each variant and compare
medians, not single samples — Postman's Collection Runner (Run button on the
collection, set Iterations) can do this without manual re-clicking.

## Optional: scripted repeats with Newman

If you have Newman installed (`npm install -g newman`), you can run N
iterations from the CLI and get a summary without manually clicking:

```sh
newman run shoplens-analyze-perf.postman_collection.json \
  -e shoplens-local.postman_environment.json \
  -n 5 --reporters cli
```

To isolate just one request (e.g. only **2. Identify - Fixed Crop**, skipping
the analyze call) use `--folder`:

```sh
newman run shoplens-analyze-perf.postman_collection.json \
  -e shoplens-dev-cloud.postman_environment.json \
  --folder "2. Identify - Fixed Crop" -n 5 --reporters cli
```
