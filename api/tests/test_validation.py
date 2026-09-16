"""Unit tests for pure logic — no database, no network, milliseconds to run.

The database-dependent behaviour is covered by the integration test
(scripts/smoke.sh), which runs against the real stack.
"""

from app import MAX_TITLE_LENGTH, validate_title


def test_accepts_a_normal_title():
    title, error = validate_title({"title": "Learn Docker"})
    assert error is None
    assert title == "Learn Docker"


def test_strips_surrounding_whitespace():
    title, error = validate_title({"title": "  Learn Kubernetes  "})
    assert error is None
    assert title == "Learn Kubernetes"


def test_rejects_missing_title():
    title, error = validate_title({})
    assert title is None
    assert "required" in error


def test_rejects_non_string_title():
    title, error = validate_title({"title": 42})
    assert title is None
    assert error is not None


def test_rejects_empty_title():
    title, error = validate_title({"title": ""})
    assert title is None
    assert "empty" in error


def test_rejects_whitespace_only_title():
    title, error = validate_title({"title": "     "})
    assert title is None
    assert "empty" in error


def test_rejects_overlong_title():
    title, error = validate_title({"title": "x" * (MAX_TITLE_LENGTH + 1)})
    assert title is None
    assert str(MAX_TITLE_LENGTH) in error


def test_accepts_title_at_exactly_the_limit():
    title, error = validate_title({"title": "x" * MAX_TITLE_LENGTH})
    assert error is None
    assert len(title) == MAX_TITLE_LENGTH


def test_rejects_non_dict_body():
    title, error = validate_title(None)
    assert title is None
    assert "JSON object" in error
