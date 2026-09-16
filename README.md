# Project 2 — Three-Tier Application with Docker Compose

[![CI](https://github.com/Lingikaushikreddy/three-tier-devops/actions/workflows/ci.yml/badge.svg)](https://github.com/Lingikaushikreddy/three-tier-devops/actions/workflows/ci.yml)

**nginx → Flask API → PostgreSQL**, three containers, one command, with health checks,
network segmentation, persistent storage and a CI pipeline that stands the whole stack
up and tests it end to end.

---

## The architecture

```
                    your laptop / the internet
                              │
                              │  only this port is open
                              ▼
                    ┌───────────────────┐
                    │  web  ·  nginx    │   :8080 → :80
                    │  static + proxy   │
                    └─────────┬─────────┘
                              │  frontend network
                              ▼
                    ┌───────────────────┐
                    │  api  ·  Flask    │   :8000, NOT published
                    │  gunicorn, 2 wkrs │
                    └─────────┬─────────┘
                              │  backend network
                              ▼
                    ┌───────────────────┐
                    │  db  · PostgreSQL │   :5432, NOT published
                    │  named volume     │
                    └───────────────────┘
```

**Two separate networks is the whole security idea.** `web` sits only on `frontend`,
`db` sits only on `backend`, and `api` is the single thing on both. nginx cannot even
*resolve the hostname* `db` — there's a test that proves it.

---

## Run it

```bash
cp .env.example .env     # never commit the real .env
docker compose up -d --build
open http://localhost:8080
```

Then run the integration test:

```bash
./scripts/smoke.sh       # 19 checks, end to end
```

Shut down:

```bash
docker compose down      # stop, KEEP the data
docker compose down -v   # stop, DELETE the data
```

> **Port 8080 busy?** Set `WEB_PORT=9090` in `.env` and `docker compose up -d` again.

---

## The API

Everything goes through nginx on `:8080` — you never talk to Flask directly.

| Method | Route | Does |
|---|---|---|
| `GET` | `/health` | app **and** database status (`503` if the DB is down) |
| `GET` | `/nginx-health` | proxy only — answers even when the API is dead |
| `GET` | `/api/tasks` | list all tasks |
| `POST` | `/api/tasks` | create — `{"title":"..."}` |
| `GET` | `/api/tasks/<id>` | read one |
| `PATCH` | `/api/tasks/<id>` | `{"done":true}` |
| `DELETE` | `/api/tasks/<id>` | delete → `204` |

```bash
curl http://localhost:8080/health
curl http://localhost:8080/api/tasks
curl -X POST http://localhost:8080/api/tasks \
     -H 'Content-Type: application/json' -d '{"title":"Learn Compose"}'
```

---

## The six ideas worth stealing from this repo

### 1. `depends_on` alone does not work

This is the single most common Docker Compose bug:

```yaml
depends_on: [db]                  # ❌ waits for the container to START
depends_on:
  db:
    condition: service_healthy    # ✅ waits for Postgres to ACCEPT QUERIES
```

A Postgres container is "started" several seconds before it can answer a query. Without
`condition: service_healthy`, the API boots first, fails to connect, and crashes.

### 2. A health check should check the thing that actually breaks

```python
@app.get("/health")
def health():
    db_ok = ping()                      # actually queries the database
    return jsonify(...), 200 if db_ok else 503
```

A health check that only confirms "the web server is running" will report healthy while
every request fails. Ours returns **503** when the database is unreachable, so a load
balancer would correctly take it out of rotation.

### 3. Don't publish what nobody outside needs

The `db` and `api` services have **no `ports:` section at all.** They're reachable only
from inside the Docker network. Getting into the database means going through Docker:

```bash
docker compose exec db psql -U postgres -d tasks
```

Every published port is a door. Only open the ones you need.

### 4. Secrets come from the environment, never from the code

`.env` is gitignored; `.env.example` (with fake values) is committed so other people know
which variables exist. In CI, GitHub Secrets fill the same role. Nothing in this repo
contains a real credential.

### 5. Named volumes are the difference between a database and a cache

```yaml
volumes:
  - pgdata:/var/lib/postgresql/data
```

Without it, your data dies with the container. Verified in both directions:

| Command | Task created before it | Seed data |
|---|---|---|
| `docker compose down` then `up` | **still there** ✅ | unchanged |
| `docker compose down -v` then `up` | **gone (404)** | re-seeded from `db/init.sql` |

`db/init.sql` runs **only** when the volume is first created. Changed it and seeing
nothing happen? You need `down -v`.

### 6. Unit tests and integration tests answer different questions

| | `api/tests/` (9 tests) | `scripts/smoke.sh` (19 checks) |
|---|---|---|
| Speed | milliseconds | ~30 seconds |
| Needs containers | no | the whole stack |
| Proves | the logic is right | the *system* is wired right |
| Catches | a bad validation rule | wrong nginx route, bad DB URL, missing healthcheck |

CI runs the fast one first and only builds the stack if it passes.

---

## The CI pipeline

```
push / PR
   │
   ├─ Job 1: unit ──────────────────────────────┐
   │    ruff check .                             │
   │    pytest -v              (9 tests)         │
   │                                             │
   └─ Job 2: integration  ◄── needs: unit
        docker compose config --quiet    (is the YAML even valid?)
        docker compose up -d --build     (build all three tiers)
        ./scripts/smoke.sh               (19 end-to-end checks)
        docker compose logs   ← only `if: failure()`
        docker compose down -v ← `if: always()`, so nothing leaks between runs
```

`if: always()` on the teardown matters — without it, a failed test leaves containers and
volumes behind and the *next* run fails for a completely unrelated reason.

---

## Bugs I hit building this (kept on purpose)

**A security test that lied.** My first version checked for an exposed database like this:

```bash
docker compose ps --format '{{.Publishers}}' | grep -q '5432'   # ❌
```

It failed — but the stack was fine. `Publishers` prints `[{ 5432 0 tcp}]`, where `5432`
is the **container** port and `0` means *not published*. The grep matched the wrong
number. The fix asks Docker for ground truth instead:

```bash
docker inspect --format '{{json .NetworkSettings.Ports}}' tt-db
# {"5432/tcp":null}   ← null = not published
```

**Then `nc -z 127.0.0.1 5432` succeeded**, which looked like proof the database *was*
exposed. It wasn't: `lsof -nP -iTCP:5432 -sTCP:LISTEN` showed an unrelated Postgres
installed natively on my Mac. Two lessons in one bug — *a test that fails may be wrong
itself*, and *always find out which process owns a port before drawing conclusions.*

---

## Layout

```
three-tier-devops/
├── docker-compose.yml        # the orchestration: 3 services, 2 networks, 1 volume
├── .env.example              # which variables exist (no real secrets)
├── api/
│   ├── app.py                # routes + validation
│   ├── db.py                 # connection pool, parameterised queries
│   ├── tests/                # 9 unit tests, no DB needed
│   └── Dockerfile            # multi-stage, non-root, healthcheck
├── nginx/
│   ├── nginx.conf            # reverse proxy + forwarded headers
│   └── index.html            # small status page
├── db/init.sql               # schema + indexes + seed data
├── scripts/smoke.sh          # 19-check integration test
├── Makefile                  # make up / smoke / logs / psql / clean
└── .github/workflows/ci.yml  # unit → integration
```

---

## Handy commands

```bash
make up        # build + start everything
make ps        # status and health of each tier
make logs      # follow all three tiers at once
make smoke     # run the integration test
make psql      # database shell (the only way in)
make down      # stop, keep data
make reset     # stop, wipe data
```

---

## What to try next

- Stop just the database (`docker compose stop db`) and watch `/health` return **503**
  while `/nginx-health` stays **200**. That's why you separate them.
- Scale the API: `docker compose up -d --scale api=3`. nginx load-balances automatically.
- Add Prometheus + Grafana as a fourth and fifth service.
- Move this to Kubernetes: each service becomes a Deployment + Service, `.env` becomes a
  ConfigMap and a Secret, and the healthchecks become liveness/readiness probes.
