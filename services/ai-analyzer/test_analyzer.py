import analyzer


def test_session_retry_does_not_wrap_read_timeouts():
    # read=False (the literal bool) is required, NOT 0 or None — both of
    # those still route a read-timeout through urllib3's retry-accounting,
    # which re-raises it wrapped as requests.exceptions.ConnectionError even
    # though zero retries actually happen. That silently breaks any caller
    # catching requests.exceptions.Timeout specifically — e.g. _google_lens's
    # `_tls.lens_timed_out` flag, which gates the /identify recovery path.
    # Regression: broke exactly this way in production on 2026-07-03 with
    # read=0; caught by comparing live logs before/after this fix.
    adapter = analyzer._session.get_adapter("https://serpapi.com")
    assert adapter.max_retries.read is False


def test_normalize_country_defaults_empty_to_us():
    assert analyzer.normalize_country(None) == "us"
    assert analyzer.normalize_country("") == "us"
    assert analyzer.normalize_country("   ") == "us"


def test_normalize_country_lowercases_and_strips():
    assert analyzer.normalize_country(" GB ") == "gb"


def test_currency_for_country_known_and_default():
    assert analyzer.currency_for_country("gb") == "GBP"
    assert analyzer.currency_for_country("de") == "EUR"
    assert analyzer.currency_for_country("in") == "INR"
    assert analyzer.currency_for_country(None) == "USD"
    assert analyzer.currency_for_country("") == "USD"
    # Country with no currency mapping falls back to USD rather than raising.
    assert analyzer.currency_for_country("zz") == "USD"


def test_build_preference_block_empty_when_no_preferences():
    assert analyzer._build_preference_block([], []) == ""
    assert analyzer._build_preference_block(None, None) == ""


def test_build_preference_block_includes_categories_and_terms():
    block = analyzer._build_preference_block(["minimalist", "Nike"], ["Electronics"])
    assert "Electronics" in block
    assert "minimalist" in block
    assert "Nike" in block
    assert "preferred items first" in block.lower() or "order" in block.lower()


def test_prioritize_items_moves_category_matches_first():
    items = [
        {"name": "ceramic mug", "box": None},
        {"name": "wireless headphones", "box": None},
        {"name": "wooden chair", "box": None},
    ]
    result = analyzer._prioritize_items(items, preference_terms=[], shopping_categories=["Electronics"])
    assert result[0]["name"] == "wireless headphones"


def test_prioritize_items_moves_preference_term_matches_first():
    items = [
        {"name": "plain white mug", "box": None},
        {"name": "Nike running shoes", "box": None},
    ]
    result = analyzer._prioritize_items(items, preference_terms=["nike"], shopping_categories=[])
    assert result[0]["name"] == "Nike running shoes"


def test_prioritize_items_no_op_without_preferences():
    items = [{"name": "a", "box": None}, {"name": "b", "box": None}]
    result = analyzer._prioritize_items(items, preference_terms=[], shopping_categories=[])
    assert result == items


def test_prioritize_items_is_stable_within_priority_tier():
    items = [
        {"name": "chair one", "box": None},
        {"name": "chair two", "box": None},
        {"name": "lamp", "box": None},
    ]
    result = analyzer._prioritize_items(items, preference_terms=[], shopping_categories=["Furniture"])
    assert [i["name"] for i in result] == ["chair one", "chair two", "lamp"]


def test_prioritize_items_preference_only_match_beats_no_match_item():
    # Regression test: a preference-only match (no category match) must still
    # outrank an item matching neither signal — previously a strict
    # (category_hit, preference_hit) tuple sort ranked ALL category matches
    # above ALL preference-only matches, which was fine, but this case
    # (preference-only vs nothing) already worked before and must keep working.
    items = [
        {"name": "plain ceramic coffee mug", "box": None},
        {"name": "black rubber strap smart watch", "box": None},
    ]
    result = analyzer._prioritize_items(
        items, preference_terms=["smart watch"], shopping_categories=["Electronics"],
    )
    assert result[0]["name"] == "black rubber strap smart watch"


def test_prioritize_items_dual_match_beats_single_match():
    # Regression test for the real bug: an item matching BOTH category and
    # preference (score 2) should outrank items matching only one signal
    # (score 1 each) — the two single-signal items are tied, so stable sort
    # preserves their original relative order (keyboard was listed first).
    items = [
        {"name": "black plastic full-size keyboard", "box": None},          # category only -> 1
        {"name": "black rubber strap smart watch", "box": None},            # preference only -> 1
        {"name": "Nike black electronics gaming keyboard", "box": None},    # category + preference -> 2
    ]
    result = analyzer._prioritize_items(
        items, preference_terms=["nike", "smart watch"], shopping_categories=["Electronics"],
    )
    assert [i["name"] for i in result] == [
        "Nike black electronics gaming keyboard",
        "black plastic full-size keyboard",
        "black rubber strap smart watch",
    ]


def test_prioritize_items_category_no_longer_unconditionally_beats_preference():
    # The exact real-world case this fix addresses: a category-only match
    # (laptop, via the "Electronics" keyword list) must not automatically
    # outrank a preference-only match (smart watch, via an explicit
    # preference term) when neither matches on both signals — they should
    # score equally (1 point each) and fall back to original relative order.
    items = [
        {"name": "black rubber strap smart watch", "box": None},   # preference only -> score 1
        {"name": "black metal frame portable laptop", "box": None},  # category only -> score 1
    ]
    result = analyzer._prioritize_items(
        items, preference_terms=["smart watch"], shopping_categories=["Electronics"],
    )
    # Equal scores (1 each) -> stable sort preserves original order (watch was first).
    assert [i["name"] for i in result] == [
        "black rubber strap smart watch",
        "black metal frame portable laptop",
    ]


def test_term_matches_handles_plural_and_singular():
    assert analyzer._term_matches("laptops", "black metal frame portable laptop") is True
    assert analyzer._term_matches("laptop", "grey metal ergonomic laptop stand") is True
    assert analyzer._term_matches("nike", "nike black running shoes") is True
    assert analyzer._term_matches("laptops", "wireless mouse") is False


def test_term_matches_handles_compound_word_spacing():
    # Preference typed with a space must still match Gemini's one-word
    # phrasing, and vice versa — a real preference-ranking miss where
    # "smartwatch" scored 0 against a "Smart Watch" preference.
    assert analyzer._term_matches("smart watch", "black rectangular smartwatch") is True
    assert analyzer._term_matches("smartwatch", "black rectangular smart watch") is True
    assert analyzer._term_matches("smart watch", "wireless mouse") is False


def test_prioritize_items_compound_word_preference_beats_generic_category_match():
    items = [
        {"name": "Black rectangular smartwatch"},
        {"name": "Acer Predator black gaming laptop"},
    ]
    # Before the compound-word fix, the smartwatch scored 0 (no preference
    # credit, no category keyword match) and lost to the laptop's generic
    # "Electronics" category hit despite being the user's literal preference.
    result = analyzer._prioritize_items(items, ["Smart Watch"], ["Electronics"])
    assert result[0]["name"] == "Black rectangular smartwatch"


def test_preference_score_sums_category_and_multiple_preference_matches():
    item = {"name": "nike black electronics gaming laptop"}
    # category hit (laptop) + 2 preference hits (nike, laptops~laptop) = 3
    assert analyzer._preference_score(item, ["nike", "laptops"], ["Electronics"]) == 3
    # category hit only = 1
    assert analyzer._preference_score(item, [], ["Electronics"]) == 1
    # single preference hit only = 1
    assert analyzer._preference_score(item, ["nike"], []) == 1
    # no hits = 0
    assert analyzer._preference_score({"name": "plain white mug"}, ["nike"], ["Electronics"]) == 0


def test_results_per_item_uses_dial_when_multiple_items():
    assert analyzer._results_per_item(3, max_searches=2) == 2
    assert analyzer._results_per_item(3, max_searches=None) == analyzer.MAX_SEARCHES_PER_RUN


def test_results_per_item_ignores_dial_for_single_item():
    assert analyzer._results_per_item(1, max_searches=2) == analyzer.MAX_RESULTS_PER_ITEM


def test_results_per_item_multi_item_never_exceeds_dial_ceiling():
    # An out-of-range dial value clamps to MAX_SEARCHES_PER_RUN (5) before the
    # MAX_RESULTS_PER_ITEM (15) ceiling is even considered — the dial's own
    # ceiling is tighter, so it's what wins here.
    assert analyzer._results_per_item(3, max_searches=999) == analyzer.MAX_SEARCHES_PER_RUN
