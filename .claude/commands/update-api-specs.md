Update the detailed OpenAPI specs under `docs/postman/apiSpecs/` after an API change.

Run `python docs/postman/generate_api_specs_detailed.py` from the repo root — but read the rest of this first, because unlike a pure regeneration, this spec has a hand-maintained enrichment layer that needs checking for drift before you just re-run the script.

## Why this isn't a one-command regenerate

`docs/postman/generate_api_specs_detailed.py` builds each spec in two layers:

1. **Request-side schemas** — pulled live from each service's FastAPI app via `generate_local()` (imports `services/{service}/main.py` and calls `app.openapi()`). This layer is always accurate automatically, because it reads the real Pydantic models.
2. **Response-side schemas, examples, `servers`, and the Voice Assistant security scheme** — hand-written in this script's `enrich_ai_analyzer()` / `enrich_product_matcher()` / `enrich_state_manager()` / `enrich_voice_assistant()` / `enrich_pubsub_worker()` functions. FastAPI can't auto-generate these because none of the routes declare a `response_model=` (they return `JSONResponse` directly) — so layer 2 only stays correct if a human (you) keeps it in sync with the code.

So "the API changed" could mean either "a request field changed" (layer 1 self-heals) or "a response shape/status code changed" (layer 2 needs a matching edit, or the detailed spec silently goes stale while still looking complete).

## Steps

1. **Find what changed.** Diff the relevant service's `main.py` (and its model-holding sibling — `analyzer.py`, `matcher.py`, `state_manager.py`, `live_session.py`/`profile_store.py`) against what's currently in `docs/postman/apiSpecs/{service}.openapi.json`. Look specifically for:
   - New/removed/renamed endpoints
   - New/removed/renamed fields on any request or response model
   - New status codes returned (check `responses={...}` in the route decorator and any `raise HTTPException(...)` / manual `JSONResponse(status_code=...)` in the handler body)
   - Changed error-response shape (e.g. a service adding an `error_code` field it didn't have before)
2. **Patch the enrichment.** If layer 2 needs updating, edit the matching `enrich_<service>()` function in `docs/postman/generate_api_specs_detailed.py`:
   - Update/add schema definitions in `schemas["..."]`
   - Update/add `responses[...]` entries via the `_resp(description, schema_ref, example, content_type=...)` helper
   - Update/add request-body `examples` via the `_req_examples({key: (summary, value)})` helper
   - If it's a genuinely new endpoint, add a new `p["/new/path"]["method"]` block following the existing pattern for that service
3. **Regenerate:**
   ```bash
   python docs/postman/generate_api_specs_detailed.py                        # all 5
   python docs/postman/generate_api_specs_detailed.py --service <name>       # just the one that changed
   ```
   Requires that service's `requirements.txt` deps installed in the Python environment running this (not real GCP credentials — see `generate_local()` in `generate_openapi_specs.py` for why that's safe).
4. **Validate** the regenerated file(s) are still well-formed OpenAPI 3.0:
   ```bash
   python -m pip install --quiet openapi-spec-validator   # once, if not already installed
   python -m openapi_spec_validator docs/postman/apiSpecs/<service>.openapi.json
   ```
5. Report back: which endpoint(s)/field(s) changed, what you edited in the enrichment script, and confirm the validator passed. If you also touched the *raw* spec's source of truth in a way that's routine (just new Pydantic fields, no response/error-code changes), it's fine to say layer 2 needed no changes — don't invent edits that aren't needed.

## Also keep in sync (not part of the regenerate, but same root cause)

- `docs/api-specs/*.openapi.json` — the raw, unenriched specs. Regenerate with `python docs/postman/generate_openapi_specs.py` (same underlying `generate_local()`, no enrichment layer, no drift risk).
- `docs/postman/shoplens-all-services.postman_collection.json` — if you added/removed an endpoint, the Postman collection should probably get a matching request too. See `/run-postman-tests` and `docs/postman/postman-how-to-run.md`.

## Known limitation

`docs/postman/apiSpecs/index.html` (Swagger UI) can't be opened directly via `file://` — browsers block `fetch()` of local files. Tell the user to serve it: `cd docs/postman/apiSpecs && python -m http.server 8000`, then open `http://localhost:8000/index.html`.
