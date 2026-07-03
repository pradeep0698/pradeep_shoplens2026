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


def test_parse_amazon_result_falls_back_to_query_name_and_amazon_search_link():
    parsed = matcher._parse_amazon_result({"price": "$19.99"}, "wireless mouse")
    assert parsed["name"] == "wireless mouse"
    assert parsed["seller"] == "Amazon"
    assert parsed["price"] == 19.99
    assert parsed["purchase_url"].startswith("https://www.amazon.com/s?k=")


def test_parse_amazon_result_prefers_link_over_fallback():
    parsed = matcher._parse_amazon_result(
        {"title": "Echo Dot", "link": "https://amazon.example/echo-dot", "extracted_price": 25.0},
        "echo dot",
    )
    assert parsed["purchase_url"] == "https://amazon.example/echo-dot"
    assert parsed["price"] == 25.0


def test_parse_amazon_result_handles_nested_price_object():
    parsed = matcher._parse_amazon_result(
        {"title": "Widget", "price": {"raw": "$12.34", "value": 12.34}}, "widget"
    )
    assert parsed["price"] == 12.34


def test_parse_amazon_result_falls_back_to_thumbnails_list():
    parsed = matcher._parse_amazon_result(
        {"title": "Widget", "thumbnails": ["https://example.com/a.jpg"]}, "widget"
    )
    assert parsed["image_url"] == "https://example.com/a.jpg"


def test_merge_dedup_appends_new_and_skips_duplicates():
    existing = [{"product_id": "a"}, {"product_id": "b"}]
    new = [{"product_id": "b"}, {"product_id": "c"}, {"product_id": "d"}]

    merged = matcher._merge_dedup(existing, new, cap=4)

    assert [p["product_id"] for p in merged] == ["a", "b", "c", "d"]


def test_merge_dedup_respects_cap():
    existing = [{"product_id": "a"}]
    new = [{"product_id": "b"}, {"product_id": "c"}]

    merged = matcher._merge_dedup(existing, new, cap=2)

    assert [p["product_id"] for p in merged] == ["a", "b"]


def test_search_products_appends_amazon_when_google_tiers_are_short(monkeypatch):
    """Tier 3 (amazon) must append to, not replace, whatever Google Shopping
    already found — unlike the old bing_shopping fallback, which fully
    replaced results on empty."""
    matcher._cache.clear()

    def fake_shopping_search(query, num, engine="google_shopping"):
        if engine == "google_shopping":
            return [
                {"product_id": "g1", "name": "Google Item 1"},
                {"product_id": "g2", "name": "Google Item 2"},
            ]
        if engine == "amazon":
            return [
                {"product_id": "a1", "name": "Amazon Item 1"},
                {"product_id": "a2", "name": "Amazon Item 2"},
                {"product_id": "a3", "name": "Amazon Item 3"},
            ]
        return []

    monkeypatch.setattr(matcher, "_shopping_search", fake_shopping_search)

    results = matcher.search_products("wireless headphones", max_results=15)

    assert [r["product_id"] for r in results] == ["g1", "g2", "a1", "a2", "a3"]


def test_search_products_skips_amazon_when_google_tier_already_has_five(monkeypatch):
    matcher._cache.clear()
    calls = []

    def fake_shopping_search(query, num, engine="google_shopping"):
        calls.append(engine)
        if engine == "google_shopping":
            return [{"product_id": f"g{i}", "name": f"Item {i}"} for i in range(5)]
        return [{"product_id": "a1", "name": "Amazon Item"}]

    monkeypatch.setattr(matcher, "_shopping_search", fake_shopping_search)

    results = matcher.search_products("desk lamp", max_results=15)

    assert len(results) == 5
    assert "amazon" not in calls


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

    # 5 results so Tier 1 alone satisfies the "under 5" threshold and Tiers
    # 2/3 never fire — keeps this test's "exactly 1 real HTTP call" intent
    # intact under the new append-on-insufficient tiering logic.
    payload = {
        "shopping_results": [
            {"title": f"Item {i}", "source": "Store"} for i in range(5)
        ]
    }

    def fake_get(*args, **kwargs):
        calls.append(kwargs.get("params", {}).get("q"))
        return _FakeResponse(payload)

    monkeypatch.setattr(matcher._session, "get", fake_get)

    matcher.search_products("desk lamp", max_results=5)
    matcher.search_products("desk lamp", max_results=5)

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
    # Each search_products call tries Tier 1 (google_shopping, 1 call) then,
    # since results are still under 5, Tier 3 (amazon, 1 call) — Tier 2 is
    # skipped since there's no price phrase to strip. 2 calls x 2
    # search_products invocations = 4 SerpAPI calls total.
    assert len(calls) >= 4


def test_search_endpoint_rejects_max_results_over_the_pydantic_bound():
    client = TestClient(main.app)

    response = client.post("/search", json={"query": "lamp", "max_results": 99})

    assert response.status_code == 422


def test_search_endpoint_passes_through_valid_max_results_uncapped(monkeypatch):
    # Regression guard for a pre-existing bug: /search used to run
    # clamp_max_searches (intended only for /match's SerpAPI-call-count cap)
    # on max_results, silently overriding any requested value down to 5
    # regardless of the Pydantic ge=1/le=20 bound. max_results must now pass
    # straight through to search_products unmodified.
    monkeypatch.setattr(
        main, "search_products", lambda query, max_results: [{"name": query, "max_results": max_results}]
    )
    client = TestClient(main.app)

    response = client.post("/search", json={"query": "lamp", "max_results": 15})

    assert response.status_code == 200
    assert response.json()["products"] == [{"name": "lamp", "max_results": 15}]
