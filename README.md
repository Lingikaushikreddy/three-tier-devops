# Project 2 — Three-Tier Application with Docker Compose

[![CI](https://github.com/Lingikaushikreddy/three-tier-devops/actions/workflows/ci.yml/badge.svg)](https://github.com/Lingikaushikreddy/three-tier-devops/actions/workflows/ci.yml)

**nginx → Flask API → PostgreSQL**, plus **Prometheus + Grafana** monitoring — seven
containers, one command. Health checks, network segmentation, persistent storage,
provisioned dashboards, alert rules, and a CI pipeline that stands the whole thing up,
tests it end to end, then **breaks the database on purpose to prove the alerts fire.**

---

## The architecture

```
                    your laptop / the internet
                       │            │           │
                    :8080        :9090       :3000
                       ▼            │           │
             ┌───────────────────┐  │           │
             │  web  ·  nginx    │  │           │
             └─────────┬─────────┘  │           │
                       │ frontend   │           │
                       ▼            │           │
             ┌───────────────────┐  │           │
             │  api  ·  Flask    │◄─┤ scraped   │
             │  /metrics         │  │           │
             └─────────┬─────────┘  │           │
                       │ backend    │           │
                       ▼            │           │
             ┌───────────────────┐  │           │
             │  db  · PostgreSQL │  │           │
             └─────────┬─────────┘  │           │
                       │            │           │
             ┌─────────▼─────────┐  │           │
             │ postgres-exporter │◄─┤           │
             └───────────────────┘  │           │
             ┌───────────────────┐  │           │
             │ cadvisor          │◄─┘           │
             └───────────────────┘              │
             ┌───────────────────┐              │
             │ prometheus        │◄─────────────┘
             │ 15d retention     │   queried by grafana
             └───────────────────┘
```

| Service | Port | Purpose |
|---|---|---|
| `web` | **8080** | nginx: static page + reverse proxy |
| `api` | internal | Flask + gunicorn, exposes `/metrics` |
| `db` | internal | PostgreSQL |
| `prometheus` | **9090** | scrapes, stores, evaluates alert rules |
| `grafana` | **3000** | dashboards (`admin`/`admin`) |
| `postgres-exporter` | internal | turns Postgres stats into metrics |
| `cadvisor` | internal | per-container CPU/memory |

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

Then open:

| | |
|---|---|
| App | http://localhost:8080 |
| Prometheus targets | http://localhost:9090/targets |
| Prometheus alerts | http://localhost:9090/alerts |
| Grafana dashboard | http://localhost:3000 → *Three-Tier Stack → Overview* |

And run the tests:

```bash
./scripts/smoke.sh       # 35 checks, end to end
./scripts/chaos.sh       # 12 checks: kill the DB, prove the alert fires
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

| | `api/tests/` (15 tests) | `scripts/smoke.sh` (35 checks) |
|---|---|---|
| Speed | milliseconds | ~30 seconds |
| Needs containers | no | the whole stack |
| Proves | the logic is right | the *system* is wired right |
| Catches | a bad validation rule | wrong nginx route, bad DB URL, missing healthcheck |

CI runs the fast one first and only builds the stack if it passes.

---

## Monitoring: the four lessons

### 1. Instrument the RED metrics, then one business metric

**R**ate, **E**rrors, **D**uration — almost every service dashboard worth having is built
from those three. This app exports:

| Metric | Type | Why |
|---|---|---|
| `http_requests_total{method,endpoint,status}` | counter | rate and errors |
| `http_request_duration_seconds` | histogram | latency percentiles |
| `tasks_total{state}` | gauge | **the business metric** |
| `database_up` | gauge | dependency health |

`tasks_total` is the one people forget. CPU graphs tell you the *server* is alive;
`tasks_total` tells you the *product* works. Plenty of outages look perfectly healthy on
infrastructure dashboards.

### 2. Never put an unbounded value in a label

```python
endpoint = request.url_rule.rule      # "/api/tasks/<int:task_id>"   ✅
endpoint = request.path               # "/api/tasks/7"               ❌
```

Every distinct label value is a separate time series stored forever. Use the raw path and
a bot scanning your 404s can create millions of series and take Prometheus down. There's
a unit test (`test_route_ids_are_normalised_into_one_series`) and a smoke check enforcing
this.

### 3. gunicorn has 2 workers, and that quietly breaks counters

Each worker is its own process with its own copy of every counter. Prometheus scrapes
once and gets whichever worker answered:

```
scrape 1 → worker A → 40 requests
scrape 2 → worker B → 37 requests     ← the counter appears to go DOWN
```

Counters must never decrease, so Prometheus reads that as a restart and your `rate()`
graphs turn to noise. The fix is `prometheus_client`'s multiprocess mode: workers write
to shared files in `PROMETHEUS_MULTIPROC_DIR` and `/metrics` sums them. It needs **three**
things, and missing any one breaks it silently:

1. `PROMETHEUS_MULTIPROC_DIR` set, and the directory writable by the app user
2. `multiprocess.MultiProcessCollector(registry)` in the `/metrics` handler
3. `child_exit` in `gunicorn.conf.py` calling `mark_process_dead(worker.pid)` — without
   it, a crashed worker's numbers haunt your totals forever

`Gauge` additionally needs a `multiprocess_mode` (we use `mostrecent`), because "combine
4 workers' values into one" has no single right answer.

### 4. Dashboards and datasources belong in git, not in the UI

Everything under `monitoring/grafana/provisioning/` is applied at startup. You *could*
click all of it into Grafana's UI — and then it would exist only in Grafana's database,
be unreproducible, and disappear the moment the container is recreated. Delete the
`grafanadata` volume and run `make up`: the dashboard is still there.

---

## The bug this project actually taught me

The chaos drill exists because of a real failure found while building it.

**Symptom:** stopped the database, expected `DatabaseDown` to fire. It went `pending`,
then vanished — and `ApiDown` fired instead.

**Cause:** `/metrics` queried the database on every scrape to refresh `tasks_total`, with
no timeout. With the database gone, the connection pool blocked for 40+ seconds.
Prometheus gives up at 10s, marked the API target **down**, and therefore recorded *no*
`database_up` value at all — so the alert about the database could never fire.

```
  before:  /metrics → 40s hang → target DOWN → all API metrics lost
  after :  /metrics → 0.01s    → target UP   → database_up=0 → alert fires
```

**Fix:** a bounded query timeout (`fetch_all_bounded`, 2s) plus `connect_timeout=3` in
the connection string. Stale business numbers beat no telemetry.

**The general rule: a metrics endpoint must never block on a dependency.** If your
monitoring shares a failure mode with the thing it monitors, it will go blind exactly
when you need it. `scripts/chaos.sh` now asserts `/metrics` answers in under 5 seconds
with the database dead, so this can't regress.


---

## The CI pipeline

```
push / PR
   │
   ├─ Job 1: unit ──────────────────────────────┐
   │    ruff check .                             │
   │    pytest -v              (15 tests)        │
   │                                             │
   └─ Job 2: integration  ◄── needs: unit
        docker compose config --quiet    (is the YAML even valid?)
        docker compose up -d --build     (build all seven containers)
        ./scripts/smoke.sh               (35 end-to-end checks)
        ./scripts/chaos.sh               (12 checks: kill the DB, alert must fire)
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

## A second bug, found by accident

`docker compose ps` showed `tt-web` as **unhealthy** while the website worked perfectly.

```bash
# from the host
curl http://localhost:8080/nginx-health     # 200 OK

# from inside the container, which is what the healthcheck does
wget -qO- http://localhost/nginx-health     # Connection refused
```

`listen 80;` binds IPv4 only (`0.0.0.0:80`), but inside the container `localhost`
resolves to **both** `127.0.0.1` and `::1`, and wget tries IPv6 first. The probe was
broken, not the server. Fixed by using `127.0.0.1` explicitly in every healthcheck.

The deeper problem was that **nothing asserted container health**, so a permanently
failing probe went unnoticed. `smoke.sh` now fails if any container reports unhealthy —
because a broken health probe is just as dangerous as a broken service: it's the thing
your orchestrator uses to decide whether to restart or route traffic.

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
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml    # scrape targets
│   │   └── alerts.yml        # 6 alert rules
│   └── grafana/
│       ├── provisioning/     # datasource + dashboard loader (as code)
│       └── dashboards/       # 12-panel dashboard JSON
├── scripts/
│   ├── smoke.sh              # 35-check integration test
│   └── chaos.sh              # 12-check failure drill
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
make chaos     # kill the database, prove the alert fires
make urls      # print every UI this stack exposes
make psql      # database shell (the only way in)
make down      # stop, keep data
make reset     # stop, wipe data
```

---

## What to try next

- Stop just the database (`docker compose stop db`) and watch `/health` return **503**
  while `/nginx-health` stays **200**. That's why you separate them.
- Scale the API: `docker compose up -d --scale api=3`. nginx load-balances automatically.
- Add Alertmanager so `DatabaseDown` sends email or Slack instead of only showing in the UI.
- Move this to Kubernetes: each service becomes a Deployment + Service, `.env` becomes a
  ConfigMap and a Secret, and the healthchecks become liveness/readiness probes.
