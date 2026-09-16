"""Prometheus instrumentation.

THE GOTCHA THIS FILE EXISTS TO SOLVE
------------------------------------
gunicorn runs 2 worker processes. Each one is a separate Python process with
its own memory, so each keeps its OWN copy of every counter. Prometheus scrapes
`/metrics` once and the load balancer hands that scrape to whichever worker is
free, so you'd see a counter that jumps around at random:

    scrape 1 -> worker A -> 40 requests
    scrape 2 -> worker B -> 37 requests   <- looks like the counter went DOWN

Counters must never decrease, so Prometheus reads that as a restart and your
rate() graphs become garbage.

The fix is prometheus_client's multiprocess mode: every worker writes its
numbers into shared .db files in PROMETHEUS_MULTIPROC_DIR, and the /metrics
handler builds a registry that ADDS UP all the files. See gunicorn.conf.py for
the other half — cleaning up when a worker dies.
"""

import os
import time

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    multiprocess,
)

MULTIPROC_DIR = os.environ.get("PROMETHEUS_MULTIPROC_DIR")

# ---- The RED metrics: Rate, Errors, Duration ----------------------------
# Almost every service dashboard worth having is built from these three.

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests.",
    ["method", "endpoint", "status"],
)

LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "endpoint"],
    # Explicit buckets. The defaults go up to 10s, which is far too coarse for
    # an API that should answer in milliseconds — p95 would be meaningless.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

# ---- Business and dependency metrics ------------------------------------
# CPU graphs tell you the server is alive. These tell you the product works.

TASKS = Gauge(
    "tasks_total",
    "Tasks currently stored, split by completion state.",
    ["state"],
    # In multiprocess mode a Gauge must say how to combine workers' values.
    # 'mostrecent' = take the newest value written by any worker, which is
    # right for a number every worker reads from the same database.
    multiprocess_mode="mostrecent",
)

DB_UP = Gauge(
    "database_up",
    "1 if the database answered the last health query, 0 otherwise.",
    multiprocess_mode="mostrecent",
)


def track(app):
    """Time every request and record the outcome."""

    @app.before_request
    def _start_timer():
        from flask import g

        g._metrics_start = time.perf_counter()

    @app.after_request
    def _record(response):
        from flask import g, request

        # Use the Flask ROUTE RULE, not the raw URL. `/api/tasks/7` and
        # `/api/tasks/8` must both become `/api/tasks/<int:task_id>`, otherwise
        # every task id creates a brand-new time series and Prometheus falls
        # over. This is called a high-cardinality label, and it is the classic
        # way people take down their own monitoring.
        endpoint = request.url_rule.rule if request.url_rule else "<unmatched>"

        REQUESTS.labels(
            method=request.method,
            endpoint=endpoint,
            status=response.status_code,
        ).inc()

        start = getattr(g, "_metrics_start", None)
        if start is not None:
            LATENCY.labels(method=request.method, endpoint=endpoint).observe(
                time.perf_counter() - start
            )

        return response

    return app


def render_latest():
    """Build the /metrics payload, merging every gunicorn worker's numbers."""
    if MULTIPROC_DIR:
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        payload = generate_latest(registry)
    else:
        # Single-process fallback, e.g. `python app.py` in development.
        payload = generate_latest()
    return payload, CONTENT_TYPE_LATEST
