"""
Quick connectivity test for the AI Analyzer Cloud Run service.
Run with: python test_analyzer.py
"""
import ssl
import json
import base64
import urllib.request

ANALYZER_URL = "https://ai-analyzer-go65u5ocsa-uc.a.run.app"

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def get(path):
    req = urllib.request.Request(f"{ANALYZER_URL}{path}")
    req.add_header("Origin", "http://localhost:8080")
    with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
        return r.status, dict(r.headers), r.read().decode()

def post(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(f"{ANALYZER_URL}{path}", data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Origin", "http://localhost:8080")
    with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
        return r.status, dict(r.headers), r.read().decode()

print("=== 1. Health check ===")
try:
    status, headers, body = get("/health")
    print(f"Status: {status}")
    print(f"Body: {body}")
    cors = headers.get("Access-Control-Allow-Origin", "MISSING")
    print(f"CORS header: {cors}")
except Exception as e:
    print(f"FAILED: {e}")

print()
print("=== 2. CORS preflight (OPTIONS) ===")
try:
    req = urllib.request.Request(f"{ANALYZER_URL}/analyze", method="OPTIONS")
    req.add_header("Origin", "http://localhost:8080")
    req.add_header("Access-Control-Request-Method", "POST")
    req.add_header("Access-Control-Request-Headers", "content-type")
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        h = dict(r.headers)
    print(f"Status: {r.status}")
    print(f"Access-Control-Allow-Origin:  {h.get('Access-Control-Allow-Origin', 'MISSING')}")
    print(f"Access-Control-Allow-Methods: {h.get('Access-Control-Allow-Methods', 'MISSING')}")
    print(f"Access-Control-Allow-Headers: {h.get('Access-Control-Allow-Headers', 'MISSING')}")
except Exception as e:
    print(f"FAILED: {e}")

print()
print("=== 3. Analyze with a tiny 1x1 red PNG ===")
# Minimal valid PNG (1x1 red pixel)
TINY_PNG = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
    "z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg=="
)
try:
    status, headers, body = post("/analyze", {
        "image_data": TINY_PNG,
        "image_mime_type": "image/png",
        "ignore_terms": [],
        "transcript": "",
    })
    print(f"Status: {status}")
    parsed = json.loads(body)
    print(f"Items found: {parsed.get('items', [])}")
    cors = headers.get("Access-Control-Allow-Origin", "MISSING")
    print(f"CORS header: {cors}")
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"HTTP {e.code}: {body[:300]}")
except Exception as e:
    print(f"FAILED: {e}")
