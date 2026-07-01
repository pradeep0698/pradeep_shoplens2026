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
    monkeypatch.setattr(matcher.time, "sleep", lambda s: None)

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


def test_simplify_query_strips_price_constraints():
    assert matcher._simplify_query("headphones under $200") == "headphones"
    assert matcher._simplify_query("desk lamp less than $50") == "desk lamp"
    assert matcher._simplify_query("sofa between $300 and $600") == "sofa"
    assert matcher._simplify_query("jacket $80") == "jacket"
    assert matcher._simplify_query("wireless mouse") is None  # no price to strip


def test_search_products_does_not_cache_empty_results(monkeypatch):
    matcher._cache.clear()
    calls = []

    def fake_get(*args, **kwargs):
        calls.append(1)
        return _FakeResponse({"shopping_results": []})

    monkeypatch.setattr(matcher._session, "get", fake_get)
    monkeypatch.setattr(matcher.time, "sleep", lambda s: None)

    matcher.search_products("completely unmatchable product xyz123")
    matcher.search_products("completely unmatchable product xyz123")

    # Both calls should hit the API — empty results must not be cached.
    # Each call tries google_shopping twice (retry) + bing_shopping twice (retry) = 4 SerpAPI calls per search_products call.
    assert len(calls) >= 4


def test_search_endpoint_returns_products_and_clamps_max_results(monkeypatch):
    matcher._cache.clear()
    monkeypatch.setattr(
        main, "search_products", lambda query, max_results: [{"name": query, "max_results": max_results}]
    )
    client = TestClient(main.app)

    response = client.post("/search", json={"query": "lamp", "max_results": 99})

    assert response.status_code == 200
    assert response.json()["products"] == [{"name": "lamp", "max_results": 5}]
