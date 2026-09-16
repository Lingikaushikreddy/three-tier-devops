"""Unit tests for instrumentation. No database, no containers.

These build a throwaway Flask app and attach the same `track()` hooks the real
app uses, so the label logic can be tested in milliseconds.
"""

import re

import pytest
from flask import Flask

from metrics import render_latest, track


@pytest.fixture
def client():
    app = Flask(__name__)
    track(app)

    @app.get("/thing/<int:thing_id>")
    def thing(thing_id):
        return {"id": thing_id}

    @app.get("/boom")
    def boom():
        return {"error": "nope"}, 500

    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def _metrics_text():
    payload, _ = render_latest()
    return payload.decode()


def test_render_latest_returns_prometheus_content_type():
    _, content_type = render_latest()
    assert "text/plain" in content_type


def test_requests_are_counted(client):
    client.get("/thing/1")
    assert "http_requests_total" in _metrics_text()


def test_route_ids_are_normalised_into_one_series(client):
    """The cardinality guard.

    /thing/1 and /thing/2 must share a single label value. If the raw id were
    used, every id ever requested would become a permanent time series and
    Prometheus would eventually fall over.
    """
    for thing_id in range(1, 6):
        client.get(f"/thing/{thing_id}")

    text = _metrics_text()
    endpoints = set(re.findall(r'http_requests_total\{endpoint="([^"]+)"', text))

    assert "/thing/<int:thing_id>" in endpoints
    assert not [e for e in endpoints if re.search(r"/\d+$", e)], (
        f"raw ids leaked into labels: {endpoints}"
    )


def test_status_code_is_labelled(client):
    client.get("/boom")
    assert re.search(r'http_requests_total\{[^}]*status="500"', _metrics_text())


def test_unmatched_routes_do_not_create_series_per_url(client):
    """A 404 scanner hitting /aaa, /bbb, /ccc must not create 3 series."""
    for path in ("/aaa", "/bbb", "/ccc"):
        client.get(path)

    text = _metrics_text()
    endpoints = set(re.findall(r'http_requests_total\{endpoint="([^"]+)"', text))
    assert "<unmatched>" in endpoints
    assert "/aaa" not in endpoints


def test_latency_histogram_is_recorded(client):
    client.get("/thing/1")
    text = _metrics_text()
    assert "http_request_duration_seconds_bucket" in text
    assert "http_request_duration_seconds_count" in text
