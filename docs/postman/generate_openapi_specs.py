#!/usr/bin/env python3
"""
Generate static OpenAPI 3.0 spec files for all ShopLens services.

Usage (from repo root):
    python docs/postman/generate_openapi_specs.py

Or fetch from live deployed services instead of generating locally:
    python docs/postman/generate_openapi_specs.py --env shoplens-dev
    python docs/postman/generate_openapi_specs.py --env cookshop-dev

Requirements: run from the repo root with each service's dependencies installed,
OR use --env to pull specs from deployed Cloud Run services via HTTP.

Output: docs/api-specs/{service}.openapi.json
"""
import argparse
import json
import sys
import urllib.request
from pathlib import Path

SERVICES = ["ai-analyzer", "product-matcher", "state-manager", "voice-assistant", "pubsub-worker"]

CLOUD_RUN_URLS = {
    "shoplens-dev": {
        "ai-analyzer":      "https://ai-analyzer-935092313069.us-central1.run.app",
        "product-matcher":  "https://product-matcher-935092313069.us-central1.run.app",
        "state-manager":    "https://state-manager-935092313069.us-central1.run.app",
        "voice-assistant":  "https://voice-assistant-935092313069.us-central1.run.app",
        "pubsub-worker":    "https://pubsub-worker-935092313069.us-central1.run.app",
    },
    "cookshop-dev": {
        "ai-analyzer":      "https://ai-analyzer-82592393149.us-central1.run.app",
        "product-matcher":  "https://product-matcher-82592393149.us-central1.run.app",
        "state-manager":    "https://state-manager-82592393149.us-central1.run.app",
        "voice-assistant":  "https://voice-assistant-82592393149.us-central1.run.app",
        "pubsub-worker":    "https://pubsub-worker-82592393149.us-central1.run.app",
    },
}

LOCAL_PORTS = {
    "ai-analyzer":     8080,
    "product-matcher": 8081,
    "state-manager":   8082,
    "voice-assistant": 8083,
    "pubsub-worker":   8084,
}


def fetch_spec(url: str) -> dict:
    req = urllib.request.Request(f"{url}/openapi.json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def generate_local(service: str) -> dict:
    import importlib.util
    import os

    service_dir = Path(__file__).parent.parent.parent / "services" / service
    spec_file = service_dir / "main.py"
    if not spec_file.exists():
        raise FileNotFoundError(f"No main.py found at {spec_file}")

    sys.path.insert(0, str(service_dir))
    os.chdir(service_dir)

    spec = importlib.util.spec_from_file_location("main", spec_file)
    module = importlib.util.module_from_spec(spec)

    try:
        spec.loader.exec_module(module)
        return module.app.openapi()
    finally:
        sys.path.pop(0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--env",
        choices=list(CLOUD_RUN_URLS.keys()) + ["local"],
        default="local",
        help="Where to fetch specs from: a deployed env or local (default: local)",
    )
    parser.add_argument(
        "--service",
        choices=SERVICES,
        default=None,
        help="Generate spec for a single service only",
    )
    args = parser.parse_args()

    out_dir = Path(__file__).parent.parent / "api-specs"
    out_dir.mkdir(parents=True, exist_ok=True)

    targets = [args.service] if args.service else SERVICES

    for service in targets:
        print(f"  {service} ... ", end="", flush=True)
        try:
            if args.env == "local":
                port = LOCAL_PORTS[service]
                spec = fetch_spec(f"http://localhost:{port}")
            else:
                base_url = CLOUD_RUN_URLS[args.env][service]
                spec = fetch_spec(base_url)

            out_path = out_dir / f"{service}.openapi.json"
            out_path.write_text(json.dumps(spec, indent=2))
            print(f"OK -> {out_path.relative_to(Path(__file__).parent.parent.parent)}")
        except Exception as exc:
            print(f"FAILED: {exc}")

    print(f"\nSpecs written to {out_dir}/")
    print("Import into Postman: Import -> Link or file -> select *.openapi.json")
    print("View in Swagger UI:  https://editor.swagger.io/ -> File -> Import file")


if __name__ == "__main__":
    main()
