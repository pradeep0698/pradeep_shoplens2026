from fastapi.testclient import TestClient

import main
import matcher


class _FakeResponse:
    def __init__(self, payload: dict, status: int = 200):
        self._payload = payload
        self.status_code = status

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"status {self.status_code}")

    def json(self) -> dict:
        return self._payload


def test_parse_shopping_result_falls_back_to_query_name_and_google_shopping_link():
    parsed = matcher._parse_shopping_result({"source": "Amazon", "price": "$19.99"}, "wireless mouse")
    assert parsed["name"] == "wireless mouse"
    assert parsed["seller"] == "Amazon"
    assert parsed["price"] == 19.99
    assert parsed["purchase_url"].startswith("https://www.google.com/search?tbm=shop&q=")


def test_parse_shopping_result_prefers_link_over_fallback():
    parsed = matcher._parse_shopping_result(
        {"title": "Logitech Mouse", "source": "Logitech", "link": "https://logitech.example/mouse", "extracted_price": 25.0},
        "mouse",
    )
    assert parsed["purchase_url"] == "https://logitech.example/mouse"
    assert parsed["price"] == 25.0


def test_search_products_returns_multiple_parsed_results(monkeypatch):
    matcher._cache.clear()
    payload = {
        "shopping_results": [
            {"title": "Headphones A", "source": "Sony", "extracted_price": 49.99, "thumbnail": "a.png"},
            {"title": "Headphones B", "source": "JBL", "extracted_price": 39.99, "thumbnail": "b.png"},
        ]
    }
    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _FakeResponse(payload))

    results = matcher.search_products("wireless headphones", max_results=2)

    assert [r["name"] for r in results] == ["Headphones A", "Headphones B"]
    assert results[0]["seller"] == "Sony"


def test_search_products_caches_by_query_and_max_results(monkeypatch):
    matcher._cache.clear()
    calls = []

    def fake_get(*args, **kwargs):
        calls.append(kwargs.get("params", {}).get("q"))
        return _FakeResponse({"shopping_results": [{"title": "Item", "source": "Store"}]})

    monkeypatch.setattr(matcher._session, "get", fake_get)

    matcher.search_products("desk lamp", max_results=3)
    matcher.search_products("desk lamp", max_results=3)

    assert len(calls) == 1


def test_search_products_returns_empty_list_on_serpapi_error(monkeypatch):
    matcher._cache.clear()
    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _FakeResponse({"error": "rate limited"}))

    assert matcher.search_products("anything") == []


def test_search_products_returns_empty_list_on_no_results(monkeypatch):
    matcher._cache.clear()
    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _FakeResponse({"shopping_results": []}))

    assert matcher.search_products("nonexistent item") == []


def test_search_product_still_returns_single_best_match(monkeypatch):
    matcher._cache.clear()
    payload = {"shopping_results": [{"title": "Best Match", "source": "Store", "extracted_price": 9.99}]}
    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _FakeResponse(payload))

    product = matcher._search_product("widget")

    assert product["name"] == "Best Match"
    assert product["price"] == 9.99


def test_fetch_thumbnail_returns_bytes_and_content_type(monkeypatch):
    matcher._THUMBNAIL_CACHE.clear()

    class _ImageResponse:
        content = b"\xff\xd8\xff\xe0fake"
        headers = {"Content-Type": "image/jpeg"}

        def raise_for_status(self):
            pass

    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _ImageResponse())

    result = matcher.fetch_thumbnail("https://encrypted-tbn1.gstatic.com/shopping?q=tbn:abc")

    assert result == (b"\xff\xd8\xff\xe0fake", "image/jpeg")


def test_fetch_thumbnail_refuses_disallowed_host():
    assert matcher.fetch_thumbnail("https://evil.example.com/steal") is None


def test_fetch_thumbnail_refuses_non_http_scheme():
    assert matcher.fetch_thumbnail("file:///etc/passwd") is None


def test_fetch_thumbnail_returns_none_on_fetch_failure(monkeypatch):
    matcher._THUMBNAIL_CACHE.clear()

    def fake_get(*a, **k):
        raise RuntimeError("boom")

    monkeypatch.setattr(matcher._session, "get", fake_get)

    assert matcher.fetch_thumbnail("https://encrypted-tbn1.gstatic.com/shopping?q=tbn:abc") is None


def test_thumbnail_endpoint_returns_image_bytes(monkeypatch):
    monkeypatch.setattr(main, "fetch_thumbnail", lambda url: (b"fake-bytes", "image/jpeg"))
    client = TestClient(main.app)

    response = client.get("/thumbnail", params={"url": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:abc"})

    assert response.status_code == 200
    assert response.content == b"fake-bytes"
    assert response.headers["content-type"] == "image/jpeg"


def test_thumbnail_endpoint_returns_502_when_fetch_fails(monkeypatch):
    monkeypatch.setattr(main, "fetch_thumbnail", lambda url: None)
    client = TestClient(main.app)

    response = client.get("/thumbnail", params={"url": "https://evil.example.com/steal"})

    assert response.status_code == 502


def test_search_endpoint_returns_products_and_clamps_max_results(monkeypatch):
    matcher._cache.clear()
    monkeypatch.setattr(
        main,
        "search_products_combined",
        lambda query, max_results: ([{"name": query, "max_results": max_results}], "google_shopping"),
    )
    client = TestClient(main.app)

    # 10 is valid per SearchRequest's own le=20 constraint, but still exceeds
    # clamp_max_searches's real ceiling (MAX_SEARCHES_PER_RUN=5), so this
    # still exercises server-side clamping beyond the request's own value —
    # 99 would be rejected by pydantic's le=20 with a 422 before ever
    # reaching the route body.
    response = client.post("/search", json={"query": "lamp", "max_results": 10})

    assert response.status_code == 200
    assert response.json()["products"] == [{"name": "lamp", "max_results": 5}]
    assert response.json()["provider"] == "google_shopping"


def test_search_products_combined_uses_only_amazon_when_google_empty(monkeypatch):
    matcher._cache.clear()
    calls = []

    def fake_get(url, params=None, timeout=None):
        calls.append(params.get("engine"))
        if params.get("engine") == "google_shopping":
            return _FakeResponse({"shopping_results": []})
        return _FakeResponse({
            "organic_results": [
                {"title": "Amazon Item", "asin": "B000000000", "extracted_price": 12.5, "thumbnail": "c.png"},
            ]
        })

    monkeypatch.setattr(matcher._session, "get", fake_get)

    products, provider = matcher.search_products_combined("running shoes", max_results=3)

    assert calls == ["google_shopping", "amazon"]
    assert provider == "amazon"
    assert products[0]["name"] == "Amazon Item"
    assert products[0]["seller"] == "Amazon"
    assert products[0]["purchase_url"] == "https://www.amazon.com/dp/B000000000"


def test_search_products_combined_tops_up_with_amazon_when_google_returns_fewer_than_max_results(monkeypatch):
    """Amazon results are APPENDED to Google's whenever Google returns fewer
    than max_results — never used to replace Google's results outright."""
    matcher._cache.clear()
    calls = []

    def fake_get(url, params=None, timeout=None):
        engine = params.get("engine")
        calls.append(engine)
        if engine == "google_shopping":
            return _FakeResponse({"shopping_results": [{"title": "Google Item", "source": "Store", "extracted_price": 9.0}]})
        assert params.get("k") == "running shoes"
        return _FakeResponse({
            "organic_results": [
                {"title": "Amazon Item A", "asin": "B111111111", "extracted_price": 15.0},
                {"title": "Amazon Item B", "asin": "B222222222", "extracted_price": 18.0},
            ]
        })

    monkeypatch.setattr(matcher._session, "get", fake_get)

    products, provider = matcher.search_products_combined("running shoes", max_results=3)

    assert calls == ["google_shopping", "amazon"]
    assert provider == "google_shopping+amazon"
    assert [p["name"] for p in products] == ["Google Item", "Amazon Item A", "Amazon Item B"]
    # Google's single result is kept, not discarded in favor of Amazon-only.
    assert products[0]["seller"] == "Store"


def test_search_products_combined_skips_amazon_when_google_fully_satisfies_max_results(monkeypatch):
    matcher._cache.clear()
    calls = []

    def fake_get(url, params=None, timeout=None):
        calls.append(params.get("engine"))
        return _FakeResponse({
            "shopping_results": [
                {"title": "Google Item A", "source": "Store", "extracted_price": 9.0},
                {"title": "Google Item B", "source": "Store", "extracted_price": 11.0},
            ]
        })

    monkeypatch.setattr(matcher._session, "get", fake_get)

    products, provider = matcher.search_products_combined("desk lamp", max_results=2)

    assert calls == ["google_shopping"]
    assert provider == "google_shopping"
    assert len(products) == 2


def test_search_products_combined_returns_none_when_both_empty(monkeypatch):
    matcher._cache.clear()
    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _FakeResponse({"shopping_results": []}))

    products, provider = matcher.search_products_combined("nonexistent item xyz")

    assert products == []
    assert provider == "none"
