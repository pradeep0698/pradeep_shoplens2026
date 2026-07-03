import analyzer


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
