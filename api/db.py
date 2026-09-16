"""Database access. A connection pool, created once and reused."""

import os

from psycopg_pool import ConnectionPool

# Credentials come from the environment, injected by docker-compose.
# They are never written down in this file.
DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/tasks",
)

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


def ping():
    """True if the database answers. Used by /health."""
    try:
        _ensure_open()
        with pool.connection(timeout=3) as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
            return cur.fetchone()[0] == 1
    except Exception:
        return False
