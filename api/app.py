"""Tier 2: the application. Talks HTTP upward to nginx, SQL downward to Postgres."""

import os

from flask import Flask, jsonify, request

from db import fetch_all, fetch_one, ping

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")

MAX_TITLE_LENGTH = 200


def validate_title(payload):
    """Returns (title, error). Pure function — unit-testable without a database."""
    if not isinstance(payload, dict):
        return None, "body must be a JSON object"

    title = payload.get("title")
    if not isinstance(title, str):
        return None, "'title' is required and must be a string"

    title = title.strip()
    if not title:
        return None, "'title' cannot be empty"
    if len(title) > MAX_TITLE_LENGTH:
        return None, f"'title' must be {MAX_TITLE_LENGTH} characters or fewer"

    return title, None


@app.get("/health")
def health():
    """Reports unhealthy if the database is unreachable — that is the point.

    A health check that only says "the web server is up" is close to useless.
    """
    db_ok = ping()
    status_code = 200 if db_ok else 503
    return jsonify(
        status="healthy" if db_ok else "degraded",
        version=APP_VERSION,
        database="connected" if db_ok else "unreachable",
    ), status_code


@app.get("/api/tasks")
def list_tasks():
    rows = fetch_all(
        "SELECT id, title, done, created_at FROM tasks ORDER BY created_at DESC, id DESC"
    )
    return jsonify(tasks=[_serialize(r) for r in rows], count=len(rows))


@app.post("/api/tasks")
def create_task():
    title, error = validate_title(request.get_json(silent=True))
    if error:
        return jsonify(error=error), 400

    # Parameterised query — the value never gets concatenated into the SQL
    # string, so there is nothing for a SQL injection to hook into.
    row = fetch_one(
        "INSERT INTO tasks (title) VALUES (%s) RETURNING id, title, done, created_at",
        (title,),
    )
    return jsonify(_serialize(row)), 201


@app.get("/api/tasks/<int:task_id>")
def get_task(task_id):
    row = fetch_one(
        "SELECT id, title, done, created_at FROM tasks WHERE id = %s", (task_id,)
    )
    if row is None:
        return jsonify(error="task not found"), 404
    return jsonify(_serialize(row))


@app.patch("/api/tasks/<int:task_id>")
def toggle_task(task_id):
    payload = request.get_json(silent=True) or {}
    done = payload.get("done", True)
    if not isinstance(done, bool):
        return jsonify(error="'done' must be true or false"), 400

    row = fetch_one(
        "UPDATE tasks SET done = %s WHERE id = %s RETURNING id, title, done, created_at",
        (done, task_id),
    )
    if row is None:
        return jsonify(error="task not found"), 404
    return jsonify(_serialize(row))


@app.delete("/api/tasks/<int:task_id>")
def delete_task(task_id):
    row = fetch_one("DELETE FROM tasks WHERE id = %s RETURNING id", (task_id,))
    if row is None:
        return jsonify(error="task not found"), 404
    return "", 204


@app.errorhandler(404)
def not_found(_):
    return jsonify(error="not found"), 404


@app.errorhandler(500)
def server_error(_):
    return jsonify(error="internal server error"), 500


def _serialize(row):
    return {
        "id": row[0],
        "title": row[1],
        "done": row[2],
        "created_at": row[3].isoformat(),
    }


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=True)
