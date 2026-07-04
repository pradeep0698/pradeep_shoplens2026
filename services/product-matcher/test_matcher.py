from fastapi.testclient import TestClient

import main
import matcher


def test_session_retry_does_not_wrap_read_timeouts():
    # read=False (the literal bool) is required, NOT 0 or None — both of
    # those still route a read-timeout through urllib3's retry-accounting,
    # which re-raises it wrapped as requests.exceptions.ConnectionError even
    # though zero retries actually happen, silently breaking any caller that
    # catches requests.exceptions.Timeout specifically. Mirrors
    # services/ai-analyzer's identical regression, caught in production logs
    # on 2026-07-03.
    adapter = matcher._session.get_adapter("https://serpapi.com")
    assert adapter.max_retries.read is False


def test_rank_by_quality_prefers_priced_and_skips_unpriced_when_enough_good_ones():
    candidates = [
        {"name": "unpriced 1", "price": 0.0},
        {"name": "unpriced 2", "price": 0.0},
        {"name": "priced 1", "price": 52.0},
        {"name": "priced 2", "price": 64.0},
        {"name": "priced 3", "price": 79.0},
    ]
    result = matcher._rank_by_quality(candidates, max_results=3)
    assert [c["name"] for c in result] == ["priced 1", "priced 2", "priced 3"]


def test_rank_by_quality_backfills_with_unpriced_when_not_enough_good_ones():
    candidates = [
        {"name": "unpriced 1", "price": 0.0},
        {"name": "priced 1", "price": 52.0},
    ]
    result = matcher._rank_by_quality(candidates, max_results=3)
    assert [c["name"] for c in result] == ["priced 1", "unpriced 1"]


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


def test_search_product_defaults_to_single_best_match(monkeypatch):
    matcher._cache.clear()
    payload = {"shopping_results": [{"title": "Best Match", "source": "Store", "extracted_price": 9.99}]}
    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _FakeResponse(payload))

    products = matcher._search_product("widget")

    assert len(products) == 1
    assert products[0]["name"] == "Best Match"
    assert products[0]["price"] == 9.99


def test_search_product_returns_up_to_max_results(monkeypatch):
    matcher._cache.clear()
    # Prices start at 1, not 0 — a $0.00 item is now correctly treated as
    # "unpriced" by _rank_by_quality and deprioritized, which isn't what this
    # test is checking (see test_rank_by_quality_* for that behavior).
    payload = {"shopping_results": [
        {"title": f"Item {i}", "source": "Store", "extracted_price": float(i + 1)} for i in range(5)
    ]}
    monkeypatch.setattr(matcher._session, "get", lambda *a, **k: _FakeResponse(payload))

    products = matcher._search_product("widget", max_results=3)

    assert len(products) == 3
    assert [p["name"] for p in products] == ["Item 0", "Item 1", "Item 2"]


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
        main, "search_products",
        lambda query, max_results, country: [{"name": query, "max_results": max_results, "country": country}],
    )
    client = TestClient(main.app)

    # 15 passes SearchRequest's own le=20 bound but still exceeds
    # MAX_SEARCHES_PER_RUN (5) — clamp_max_searches() should bring it down to 5.
    response = client.post("/search", json={"query": "lamp", "max_results": 15})

    assert response.status_code == 200
    body = response.json()
    assert body["products"] == [{"name": "lamp", "max_results": 5, "country": "us"}]
    assert body["country"] == "us"
    assert body["currency"] == "USD"


def test_search_endpoint_defaults_and_normalizes_country(monkeypatch):
    matcher._cache.clear()
    seen = {}

    def fake_search_products(query, max_results, country):
        seen["country"] = country
        return []

    monkeypatch.setattr(main, "search_products", fake_search_products)
    client = TestClient(main.app)

    response = client.post("/search", json={"query": "lamp", "max_results": 5, "country": " GB "})

    assert response.status_code == 200
    assert seen["country"] == "gb"
    assert response.json()["currency"] == "GBP"


def test_shopping_search_passes_gl_param(monkeypatch):
    captured = {}

    def fake_get(url, params=None, timeout=None):
        captured.update(params or {})
        return _FakeResponse({"shopping_results": []})

    monkeypatch.setattr(matcher._session, "get", fake_get)

    matcher._shopping_search("lamp", 5, country="gb")

    assert captured["gl"] == "gb"


def test_search_product_cache_is_country_aware(monkeypatch):
    matcher._cache.clear()
    calls = []

    def fake_get(url, params=None, timeout=None):
        calls.append(params.get("gl"))
        return _FakeResponse({"shopping_results": [{"title": "Item", "source": "Store", "extracted_price": 1.0}]})

    monkeypatch.setattr(matcher._session, "get", fake_get)

    matcher._search_product("widget", country="us")
    matcher._search_product("widget", country="gb")
    matcher._search_product("widget", country="us")  # cache hit, no new call

    assert calls == ["us", "gb"]


def test_match_products_prioritizes_preference_terms_under_cap(monkeypatch):
    matcher._cache.clear()
    seen_queries = []

    def fake_search_product(item, country=matcher.DEFAULT_COUNTRY, max_results=1):
        seen_queries.append(item)
        return [{
            "product_id": f"pid-{item}", "name": item, "price": 1.0,
            "image_url": "", "purchase_url": "", "seller": "Store", "category": "General",
        }]

    monkeypatch.setattr(matcher, "_search_product", fake_search_product)

    result = matcher.match_products(
        ["plain white mug", "Nike running shoes"],
        max_searches=1,
        preference_terms=["nike"],
    )

    assert seen_queries == ["Nike running shoes"]
    assert result["country"] == "us"
    assert result["currency"] == "USD"


def test_results_per_item_uses_dial_when_multiple_items():
    assert matcher._results_per_item(3, max_searches=2) == 2
    assert matcher._results_per_item(3, max_searches=None) == matcher.MAX_SEARCHES_PER_RUN


def test_results_per_item_ignores_dial_for_single_item():
    assert matcher._results_per_item(1, max_searches=2) == matcher.MAX_RESULTS_PER_ITEM


def test_results_per_item_multi_item_never_exceeds_dial_ceiling():
    # An out-of-range dial value clamps to MAX_SEARCHES_PER_RUN (5) before the
    # MAX_RESULTS_PER_ITEM (15) ceiling is even considered — the dial's own
    # ceiling is tighter, so it's what wins here.
    assert matcher._results_per_item(3, max_searches=999) == matcher.MAX_SEARCHES_PER_RUN


def test_match_products_returns_multiple_results_for_single_item(monkeypatch):
    matcher._cache.clear()
    seen_max_results = []

    def fake_search_product(item, country=matcher.DEFAULT_COUNTRY, max_results=1):
        seen_max_results.append(max_results)
        return [
            {"product_id": f"pid-{item}-{i}", "name": f"{item} {i}", "price": float(i),
             "image_url": "", "purchase_url": "", "seller": "Store", "category": "General"}
            for i in range(max_results)
        ]

    monkeypatch.setattr(matcher, "_search_product", fake_search_product)

    result = matcher.match_products(["stand mixer"], max_searches=2)

    assert seen_max_results == [matcher.MAX_RESULTS_PER_ITEM]
    assert len(result["matched_products"]) == matcher.MAX_RESULTS_PER_ITEM


def test_match_products_caps_results_per_item_to_dial_when_multiple_items(monkeypatch):
    matcher._cache.clear()
    seen_max_results = []

    def fake_search_product(item, country=matcher.DEFAULT_COUNTRY, max_results=1):
        seen_max_results.append(max_results)
        return [
            {"product_id": f"pid-{item}-{i}", "name": f"{item} {i}", "price": float(i),
             "image_url": "", "purchase_url": "", "seller": "Store", "category": "General"}
            for i in range(max_results)
        ]

    monkeypatch.setattr(matcher, "_search_product", fake_search_product)

    result = matcher.match_products(["stand mixer", "silicone spatula"], max_searches=2)

    assert seen_max_results == [2, 2]
    assert len(result["matched_products"]) == 4


def test_prioritize_items_category_no_longer_unconditionally_beats_preference():
    # Regression test for a real bug found in production testing: a
    # category-only match (laptop, via the "Electronics" keyword list) must
    # not automatically outrank a preference-only match (smart watch, via an
    # explicit preference term) — they should score equally (1 point each)
    # and fall back to original relative order, not have category strictly
    # dominate preference.
    items = [
        "black rubber strap smart watch",     # preference only -> score 1
        "black metal frame portable laptop",  # category only -> score 1
    ]
    result = matcher._prioritize_items(
        items, preference_terms=["smart watch"], shopping_categories=["Electronics"],
    )
    assert result == ["black rubber strap smart watch", "black metal frame portable laptop"]


def test_prioritize_items_dual_match_beats_single_match():
    items = [
        "black plastic full-size keyboard",          # category only -> 1
        "black rubber strap smart watch",            # preference only -> 1
        "Nike black electronics gaming keyboard",    # category + preference -> 2
    ]
    result = matcher._prioritize_items(
        items, preference_terms=["nike", "smart watch"], shopping_categories=["Electronics"],
    )
    assert result == [
        "Nike black electronics gaming keyboard",
        "black plastic full-size keyboard",
        "black rubber strap smart watch",
    ]


def test_term_matches_handles_plural_and_singular():
    assert matcher._term_matches("laptops", "black metal frame portable laptop") is True
    assert matcher._term_matches("laptop", "grey metal ergonomic laptop stand") is True
    assert matcher._term_matches("nike", "nike black running shoes") is True
    assert matcher._term_matches("laptops", "wireless mouse") is False


def test_term_matches_handles_compound_word_spacing():
    # Preference typed with a space must still match Gemini's one-word
    # phrasing, and vice versa — a real preference-ranking miss where
    # "smartwatch" scored 0 against a "smart watch" preference.
    assert matcher._term_matches("smart watch", "black rectangular smartwatch") is True
    assert matcher._term_matches("smartwatch", "black rectangular smart watch") is True
    assert matcher._term_matches("smart watch", "wireless mouse") is False


def test_prioritize_items_compound_word_preference_beats_generic_category_match():
    items = ["Black rectangular smartwatch", "Acer Predator black gaming laptop"]
    # Before the compound-word fix, the smartwatch scored 0 (no preference
    # credit, no category keyword match) and lost to the laptop's generic
    # "electronics" category hit despite being the user's literal preference.
    result = matcher._prioritize_items(items, ["Smart Watch"], ["electronics"])
    assert result[0] == "Black rectangular smartwatch"


def test_item_score_sums_category_and_multiple_preference_matches():
    item = "nike black electronics gaming laptop"
    assert matcher._item_score(item, ["nike", "laptops"], ["electronics"]) == 3
    assert matcher._item_score(item, [], ["electronics"]) == 1
    assert matcher._item_score(item, ["nike"], []) == 1
    assert matcher._item_score("plain white mug", ["nike"], ["electronics"]) == 0


def test_currency_for_country_known_and_default():
    assert matcher.currency_for_country("gb") == "GBP"
    assert matcher.currency_for_country("de") == "EUR"
    assert matcher.currency_for_country(None) == "USD"
    assert matcher.currency_for_country("zz") == "USD"


def test_normalize_country_defaults_empty_to_us():
    assert matcher.normalize_country(None) == "us"
    assert matcher.normalize_country("") == "us"
    assert matcher.normalize_country(" GB ") == "gb"
