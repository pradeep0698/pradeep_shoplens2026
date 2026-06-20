"""
One-off generator for postman/shoplens-analyze-perf.postman_collection.json.

Re-run this if the fixed test image changes:
    python postman/_generate_collection.py

Keeps the (large) base64 image payload out of source review/diffs by
generating it programmatically instead of hand-pasting it into the
collection JSON.
"""
import base64
import json
import os

IMAGE_PATH = r"C:\ShopLens\images\image-1.webp"
IMAGE_MIME_TYPE = "image/webp"
OUT_PATH = os.path.join(os.path.dirname(__file__), "shoplens-analyze-perf.postman_collection.json")

with open(IMAGE_PATH, "rb") as f:
    image_b64 = base64.b64encode(f.read()).decode("ascii")

analyze_body = {
    "image_data": "{{image_base64}}",
    "image_mime_type": IMAGE_MIME_TYPE,
    "transcript": "",
    "ignore_terms": [],
    "query": "",
    "country": "us",
    "max_searches": 5,
}

config_test_script = [
    "let body = {};",
    "try { body = pm.response.json(); } catch (e) {}",
    "pm.collectionVariables.set(\"current_model\", body.model || \"unknown\");",
    "console.log(`[CONFIG] active_model=${body.model}`);",
]

analyze_test_script = [
    "pm.test(\"Status code is 200\", function () {",
    "    pm.response.to.have.status(200);",
    "});",
    "",
    "let body = {};",
    "try { body = pm.response.json(); } catch (e) {}",
    "",
    "const timeMs = pm.response.responseTime;",
    "const model = pm.collectionVariables.get(\"current_model\") || \"unknown\";",
    "const itemCount = (body.items || []).length;",
    "const productCount = (body.products || []).length;",
    "const warnings = body.warnings || [];",
    "const requestId = pm.response.headers.get(\"X-Request-Id\") || \"unknown\";",
    "",
    "const summary = `[ANALYZE PERF] model=${model} time_ms=${timeMs} items=${itemCount}` +",
    "    ` products=${productCount} warnings=${JSON.stringify(warnings)} request_id=${requestId}`;",
    "",
    "console.log(summary);",
    "pm.collectionVariables.set(\"last_run_summary\", summary);",
    "",
    "pm.test(`Response time captured (${timeMs} ms)`, function () {",
    "    pm.expect(timeMs).to.be.a(\"number\");",
    "});",
]

collection = {
    "info": {
        "_postman_id": "b7e4a9b0-1f2d-4a3e-9c2a-shoplens-analyze-perf",
        "name": "ShopLens Analyze API - Performance Testing",
        "description": (
            "Fixed-input performance harness for the ai-analyzer /analyze endpoint.\n\n"
            "Workflow: run '0. Check Current Model', then '1. Analyze - Fixed Test Image'. "
            "Open the Postman Console (View > Show Postman Console) to see the "
            "'[ANALYZE PERF] ...' summary line after each run, and read the response "
            "time from the response pane (top right, in ms). Record both into "
            "docs/analyze-perf-test-results.md after each run, one code change at a time.\n\n"
            "The test image is embedded as the 'image_base64' collection variable so every "
            "run sends byte-identical input regardless of who runs it or when."
        ),
        "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
    },
    "item": [
        {
            "name": "0. Check Current Model",
            "event": [
                {
                    "listen": "test",
                    "script": {"type": "text/javascript", "exec": config_test_script},
                }
            ],
            "request": {
                "method": "GET",
                "header": [],
                "url": {
                    "raw": "{{baseUrl}}/config",
                    "host": ["{{baseUrl}}"],
                    "path": ["config"],
                },
            },
            "response": [],
        },
        {
            "name": "1. Analyze - Fixed Test Image",
            "event": [
                {
                    "listen": "test",
                    "script": {"type": "text/javascript", "exec": analyze_test_script},
                }
            ],
            "request": {
                "method": "POST",
                "header": [{"key": "Content-Type", "value": "application/json"}],
                "body": {
                    "mode": "raw",
                    "raw": json.dumps(analyze_body, indent=2),
                    "options": {"raw": {"language": "json"}},
                },
                "url": {
                    "raw": "{{baseUrl}}/analyze",
                    "host": ["{{baseUrl}}"],
                    "path": ["analyze"],
                },
            },
            "response": [],
        },
    ],
    "variable": [
        {"key": "baseUrl", "value": "http://localhost:8080", "type": "string"},
        {"key": "current_model", "value": "", "type": "string"},
        {"key": "last_run_summary", "value": "", "type": "string"},
        {"key": "image_base64", "value": image_b64, "type": "string"},
    ],
}

with open(OUT_PATH, "w", encoding="utf-8") as f:
    json.dump(collection, f, indent=2)

print(f"Wrote {OUT_PATH} ({os.path.getsize(OUT_PATH):,} bytes)")
print(f"Embedded image: {IMAGE_PATH} ({os.path.getsize(IMAGE_PATH):,} bytes -> base64 {len(image_b64):,} chars)")
