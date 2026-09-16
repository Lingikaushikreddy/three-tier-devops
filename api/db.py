"""Database access. A connection pool, created once and reused."""

import os

from psycopg_pool import ConnectionPool

# Credentials come from the environment, injected by docker-compose.
# They are never written down in this file.
DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/tasks",
)

# Without connect_timeout, psycopg waits on an unreachable host until the OS
# gives up, which can be minutes. Always bound it.
if "connect_timeout" not in DATABASE_URL:
    DATABASE_URL += ("&" if "?" in DATABASE_URL else "?") + "connect_timeout=3"

# open=False so importing this module never blocks; the pool connects lazily.
# Opening a fresh TCP connection per request is one of the classic ways to
# make a fast app slow.
pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=5, open=False)


def _ensure_open():
    if pool.closed:
        pool.open()


def fetch_all(sql, params=None):
    _ensure_open()
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def fetch_one(sql, params=None):
    _ensure_open()
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def execute(sql, params=None):
    _ensure_open()
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.rowcount


def fetch_all_bounded(sql, params=None, timeout=2.0):
    """fetch_all that gives up fast. Used by /metrics only.

    A metrics endpoint must NEVER block on a dependency. If the scrape times
    out, Prometheus marks the whole target DOWN and you lose every metric this
    service publishes — including the ones that would tell you what broke.
    Stale business numbers beat no telemetry at all.
    """
    _ensure_open()
    with pool.connection(timeout=timeout) as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def ping():
    """True if the database answers. Used by /health."""
    try:
        _ensure_open()
        with pool.connection(timeout=3) as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
            return cur.fetchone()[0] == 1
    except Exception:
        return False
