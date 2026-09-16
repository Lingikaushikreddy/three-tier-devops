# Why We Used What — The Complete Story
### Every decision in these projects, explained so it stays in your head

Every technical decision in this repository, explained from first principles.

This covers two projects that build on each other:

- **[flask-docker-ci](https://github.com/Lingikaushikreddy/flask-docker-ci)** — one service:
  Docker, tests, and a CI/CD pipeline that publishes an image.
- **this repo** — three tiers plus monitoring: nginx, Flask, PostgreSQL, Prometheus, Grafana.

Read it once end to end. Then use Part 6 (the recall questions) to test yourself a week
later. Understanding fades; **retrieving** it from memory is what makes it permanent.

> Written while building these projects, so the bug stories in Part 5½ are real failures
> hit along the way — not textbook examples.

---

# Part 0 — The One Story That Explains Everything

Software has exactly one hard problem:

> **Code works on the machine where it was written. It must work on a machine nobody has ever seen, for people you'll never meet, at 3am when you're asleep.**

Every tool you used exists to close some part of that gap:

```
  I wrote code            →  does it still work?        →  pytest, ruff
  on MY machine           →  package the machine too    →  Docker
  with MY database        →  declare the whole system   →  docker-compose
  I must remember to test →  make a robot do it         →  GitHub Actions
  it's live now           →  is it still OK?            →  Prometheus, Grafana
  something broke         →  tell me before users do    →  alert rules
```

**Memory hook:** *Write it → Prove it → Pack it → Wire it → Ship it → Watch it.*

Six words. Every tool you used fits into exactly one of them. If you remember nothing
else from this file, remember those six.

---

# Part 1 — Write It & Prove It

## Python + Flask

**What it is:** Flask turns a Python function into a web page or API endpoint.

```python
@app.get("/health")
def health():
    return jsonify(status="healthy")
```

That decorator means: *when someone visits `/health`, run this function.*

**Why we used it:** We needed *some* app to containerize. Flask is the smallest real web
framework — small enough that the app never distracts from the DevOps around it.

**Remember:** Flask was the excuse, not the point. **In DevOps, the app is the cargo, not the ship.**

---

## pytest — automated tests

**Kid version:** A friend who checks your homework the exact same way every single time,
never gets bored, never gets tired, and does it in half a second.

**What it does:**
```python
def test_sum_adds_numbers(client):
    res = client.post("/api/sum", json={"numbers": [1, 2, 3, 4]})
    assert res.get_json()["sum"] == 10     # if this is false, the test FAILS
```

`assert` means "this must be true." If it isn't, the test fails and the pipeline stops.

**Why it matters more than you think:** Tests aren't about proving your code works today.
You *know* it works today — you just wrote it. Tests are about **three months from now**,
when you change something else and accidentally break this. The test catches it in 2
seconds instead of a customer catching it in production.

**Remember:** *Tests are a message to your future self: "don't break this."*

---

## ruff — the linter

**Kid version:** Spellcheck, but for code style.

**What it caught here:** `isinstance(n, (int, float))` → ruff said modern Python
prefers `isinstance(n, int | float)`. Not a bug. Just consistency.

**Why bother:** On a team of 10, without a linter you get 10 personal styles and every
code review turns into arguments about spacing instead of logic. A linter ends the
argument by being the neutral referee.

**Remember:** *A linter doesn't make code correct. It makes code boring — and boring code is readable code.*

---

# Part 2 — Pack It (Docker)

## The problem Docker solves

```
You:       "It works on my machine!"
Server:    "I don't have Python 3.12."
You:       "Just install it."
Server:    "That breaks the other app."
You:       😵
```

**Kid version:** A **lunchbox**. Your food tastes exactly the same at home, at school, at
grandma's house — because the box carries everything with it.

Docker packs your code **plus Python, plus the libraries, plus the tiny Linux it needs**
into one sealed box. It runs identically everywhere, because nothing outside the box matters.

## The three words people mix up

| Word | It is | Analogy |
|---|---|---|
| **Dockerfile** | the recipe | the instructions on paper |
| **Image** | the frozen result | the meal, sealed and frozen |
| **Container** | a running copy | the meal, heated up and being eaten |

**One image → many containers.** One recipe → many meals. That's how you scale: run the
same image 10 times.

**Remember:** *Dockerfile is the recipe, image is the frozen meal, container is dinner.*

---

## Why the Dockerfile looks the way it does

Every line in it is a decision. Here's each one:

### `FROM python:3.12-slim`
Start from a small pre-made Linux with Python already in it. `slim` = fewer programs
inside = smaller download and **fewer things that can have security holes**.

> **Rule: every program in your image is a program that can be attacked. Ship less.**

### Multi-stage build — the two `FROM` lines

```
Stage 1 "builder"                Stage 2 "runtime"
┌────────────────────┐           ┌────────────────────┐
│ install packages   │  ──copy── │ just the packages  │
│ pip cache, compilers│  only the │ + your code        │
│ (~400 MB of junk)  │  venv     │                    │
└────────────────────┘           └────────────────────┘
      THROWN AWAY                     241 MB shipped
```

You need tools to *build* something that you don't need to *run* it. You need an oven to
bake a cake; you don't deliver the oven with the cake.

**Remember:** *Build in a messy kitchen, serve on a clean plate.*

### `COPY requirements.txt` **before** `COPY app.py`

This looks pointless. It is the single biggest speed trick in Docker.

Docker builds in **layers**, and reuses (caches) any layer whose inputs haven't changed.

```
COPY requirements.txt     ← changes rarely
RUN pip install ...       ← SLOW (30s). Cached as long as requirements.txt is unchanged.
COPY app.py               ← changes constantly
```

Edit `app.py`, rebuild: Docker reuses the cached install and finishes in **1 second**.
Flip the order and every tiny code edit re-downloads Flask. Same result, 30× slower, forever.

**Remember:** *Put the things that rarely change FIRST. Cache flows top to bottom.*

### `USER appuser`

Containers run as **root** (full admin) by default. If an attacker finds a hole in your
app, do they land as an all-powerful admin, or as a nobody who can't touch anything?

**Remember:** *Root inside a container is still root. Drop it.*

### `HEALTHCHECK`

Teaches Docker the difference between two very different things:

- **"the process is running"** — gunicorn hasn't crashed
- **"the app actually works"** — it answers `/health` with 200

A frozen app is still "running". Health checks catch the difference. Run `docker ps` and
you literally see `(healthy)`.

**Remember:** *"Running" is not "working." Ask it a question and see if it answers.*

### `CMD ["gunicorn", ...]` and not `flask run`

Flask's built-in server handles **one request at a time** and prints a warning telling you
not to use it in production. gunicorn runs multiple worker processes and handles real traffic.

**Remember:** *The dev server is a bicycle. Production needs a truck.*

### `.dockerignore`

Stops files from entering the image: tests, `.git`, `.env`. Smaller image, and **secrets
never accidentally get baked in**. An image is shipped around — anything inside it travels too.

**Remember:** *Anything inside the image goes everywhere the image goes.*

---

# Part 3 — Wire It (docker-compose & the three tiers)

## Why THREE containers instead of one

**Kid version:** A restaurant has a **waiter** (takes orders), a **chef** (cooks), and a
**fridge** (stores food). You could make one person do all three. Then when they're sick,
everything stops — and the fridge has to learn to take orders.

| Tier | Container | Job |
|---|---|---|
| 1 — web | nginx | greets visitors, hands requests inward |
| 2 — app | Flask | thinks, decides, applies the rules |
| 3 — data | PostgreSQL | remembers things |

**Why separate:** Each can be scaled, restarted, updated and secured independently. Need
more thinking power? Run 5 copies of tier 2 only.

**Remember:** *Waiter, chef, fridge. Each does one job and can be replaced alone.*

---

## nginx — the reverse proxy

**Kid version:** The bouncer at the door. Everyone talks to the bouncer. Nobody walks
straight into the kitchen.

**What it actually gives you:**
- **One front door.** Only nginx has a published port. The app and database have *none*.
- Serves static files (fast) without waking the Python app at all
- Later: HTTPS, rate limiting, load balancing across many app copies live here

**Why it must exist even though Flask can serve pages:** because then Flask would be
exposed directly to the internet — and Flask is not built to be a doorman.

**Remember:** *One door in. Everything else is behind it.*

---

## docker-compose — describing the whole system

Without compose you'd type three long `docker run` commands **in the right order**, every
time, and remember every flag. With compose you write it down once:

```bash
docker compose up -d      # all of it, correctly, every time
```

**Remember:** *`docker run` is a sentence you must remember. `docker-compose.yml` is the memory.*

---

## `depends_on: condition: service_healthy` — the #1 beginner bug

```yaml
depends_on: [db]                  # ❌ waits for the container to START
depends_on:
  db:
    condition: service_healthy    # ✅ waits until it can ANSWER QUERIES
```

A Postgres container is "started" several seconds before it's ready to answer. With the
wrong version, your API boots first, can't connect, and crashes.

**Kid version:** The oven being *switched on* is not the oven being *hot*.

**Remember:** *"Started" ≠ "ready." Wait for ready.*

---

## Two networks — segmentation

```
frontend network:   web  ←→  api
backend  network:            api  ←→  db
```

nginx and the database **share no network**. nginx literally cannot resolve the hostname
`db` — there's a test in this repo that proves it.

**Why this matters:** if someone compromises nginx (the most exposed piece, on the open
internet), they still can't reach your data. They'd have to break *through* the app tier too.

**Kid version:** The front desk of a hotel can't open the safe. Different keys, different rooms.

**Remember:** *Doors you never build can't be forced.*

---

## Named volumes — why your data survives

Containers are **disposable by design**. Delete one and everything inside it dies.
That's great for apps, catastrophic for databases.

```yaml
volumes:
  - pgdata:/var/lib/postgresql/data     # lives OUTSIDE the container
```

Both directions are verified:

| Command | Your data |
|---|---|
| `docker compose down` then `up` | **still there** ✅ |
| `docker compose down -v` | **gone** — and `init.sql` re-seeds from scratch |

The `-v` means volumes. **That one letter is the difference between a restart and a data wipe.**

**Remember:** *Containers are paper plates. Volumes are the fridge.*

---

## Environment variables & `.env`

```yaml
POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-postgres}
```

Configuration comes from **outside** the code. Same image, different settings per
environment — dev, staging, production — with no code change.

- `.env` → real values → **gitignored, never committed**
- `.env.example` → fake values → committed, so others know which variables exist

**Why it's non-negotiable:** GitHub is scanned by bots within *seconds* of a push. A
committed password is a compromised password, even if you delete it a minute later —
git remembers everything.

**Remember:** *Config comes from outside. Secrets never enter git. Git never forgets.*

---

## Parameterised SQL — the one security habit to keep forever

```python
cur.execute("INSERT INTO tasks (title) VALUES (%s)", (title,))    # ✅
cur.execute(f"INSERT INTO tasks (title) VALUES ('{title}')")      # ❌ SQL injection
```

In the bad version, a user who types `'); DROP TABLE tasks;--` **runs their own commands
on your database.** In the good version, the value is sent separately from the command,
so there's nothing to break out of. It's always just text.

**Kid version:** Don't let the customer write on the order pad. Write what they say into
the box marked "order."

**Remember:** *Never glue user input into a command. Pass it as a parameter.*

---

# Part 4 — Ship It (CI/CD)

## What CI/CD actually means

- **CI (Continuous Integration)** — every time you push, a robot checks the work
- **CD (Continuous Delivery/Deployment)** — the robot also packages and ships it

**Kid version:** A robot that, every time you finish homework, checks the spelling, checks
the math, prints it, and puts it on the teacher's desk. You just write.

## Why the pipeline is ordered the way it is

```
push
 │
 ├─ Job 1: lint + unit tests        (7 seconds, cheap)
 │
 └─ Job 2: build + integration      ONLY IF Job 1 passed  ← `needs: unit`
      docker compose up
      smoke.sh   (35 checks)
      chaos.sh   (12 checks)
```

**`needs:` is the important word.** Never build and publish an image from code that
already failed its tests. Fail cheap and fast before you fail slow and expensive.

**Remember:** *Cheap checks first. Never build on top of a known failure.*

---

## Unit tests vs integration tests vs the chaos drill

This distinction is what separates beginners from professionals:

| | Unit (15) | Integration (35) | Chaos (12) |
|---|---|---|---|
| Speed | milliseconds | ~30 seconds | ~2 minutes |
| Needs containers | no | the whole stack | the whole stack |
| Question it answers | "is the logic right?" | "is the system wired right?" | "what happens when it breaks?" |
| Catches | a bad validation rule | wrong nginx route, bad DB URL | a health check that lies |

**The killer insight:** your unit tests can all pass while the container is completely
broken — wrong `CMD`, missing file, nothing listening. **Unit tests test your code.
Integration tests test your assumptions.**

This really happened here: a patch accidentally deleted the `GET /api/tasks` route.
Every unit test still passed. The smoke test caught it immediately.

**Remember:** *Unit tests check the parts. Integration tests check the wiring. Chaos tests check the alarms.*

---

## `secrets.GITHUB_TOKEN`

A temporary password GitHub creates for each pipeline run and destroys when it ends. Your
repo contains **zero** credentials.

**Remember:** *Short-lived and automatic beats long-lived and remembered.*

---

## Why pushing a pipeline needs a special permission

A `gh` token with the `repo` scope can push *code* but is refused when pushing `.github/workflows/`.

That's deliberate. A workflow is **code GitHub itself runs, with access to your secrets.**
If a stolen token could silently add a workflow, it could steal every secret you have. So
that power is a separate, explicitly granted scope.

**Remember:** *A pipeline is code that runs with the keys. It gets its own lock.*

---

# Part 5 — Watch It (Monitoring)

## Why monitoring exists

Would you drive a car with the windscreen painted black? You'd be moving. You just
wouldn't know what you're about to hit.

Without monitoring, **your users are your alerting system** — and they tell you by leaving.

---

## Prometheus PULLS. It does not receive.

This surprises everyone:

```
Prometheus  ──every 15s──►  "give me your numbers"  ──►  the app's /metrics
```

The app doesn't send anything anywhere. It just publishes a page of numbers, and
Prometheus comes and reads it on a timer.

**Why pull is better here:** Prometheus always knows if a target is unreachable (the
scrape fails → `up = 0`). With push, silence is ambiguous — is it healthy and quiet, or dead?

**Remember:** *Prometheus is a nurse doing rounds, not a patient calling for help. Silence is an answer.*

---

## The three metric types

| Type | Only goes | Example | Real-life |
|---|---|---|---|
| **Counter** | up | `http_requests_total` | car odometer |
| **Gauge** | up and down | `database_up`, `tasks_total` | speedometer |
| **Histogram** | buckets things | `http_request_duration_seconds` | "how many finished in under 50ms?" |

**Counters never decrease** — that's the rule that makes them trustworthy. If one ever
goes down, Prometheus assumes the app restarted. (Hold that thought — it caused a real bug below.)

**Remember:** *Odometer, speedometer, and a chart of how long things took.*

---

## RED — the three metrics for any service

- **R**ate — how many requests per second
- **E**rrors — how many are failing
- **D**uration — how long they take

Almost every service dashboard worth having is built from these three.

**Plus one more you must never forget: a BUSINESS metric.** Here it is `tasks_total`.

> CPU graphs tell you the **server** is alive. `tasks_total` tells you the **product works.**

Plenty of outages look completely healthy on infrastructure dashboards. The server is fine.
Nobody can save a task.

**Remember:** *RED tells you the service is up. A business metric tells you it's useful.*

---

## Percentiles, not averages

The dashboard shows **p50, p95, p99** — not "average response time."

Why: 99 requests take 10ms, one takes 10 seconds. The average is 110ms — looks fine!
But 1 in 100 of your users just had a terrible experience, and the average hid it completely.

**p95 = "95% of requests were faster than this."** It shows you the pain.

**Remember:** *Averages hide the suffering of a minority. Percentiles expose it.*

---

## The cardinality trap

```python
endpoint = request.url_rule.rule   # "/api/tasks/<int:task_id>"  ✅ ONE series
endpoint = request.path            # "/api/tasks/7"              ❌ one per id
```

Every distinct label value creates a **separate time series, stored forever**. Use the raw
path and a bot scanning your 404s can create millions of series and take Prometheus down —
you'd be killed by your own monitoring.

**Remember:** *Labels must have a small, fixed set of possible values. Never put an ID in a label.*

---

## The gunicorn multi-worker problem

gunicorn runs **2 worker processes**. Each is a separate program with its **own copy** of
every counter. Prometheus scrapes once and gets whichever worker answered:

```
scrape 1 → worker A → 40 requests
scrape 2 → worker B → 37 requests     ← the counter appears to go DOWN
```

Counters must never decrease, so Prometheus concludes "the app restarted" and your rate
graphs become garbage. **Nothing errors. Nothing warns you. The numbers are just quietly wrong.**

The fix (multiprocess mode) has **three** parts, and missing any one breaks it silently —
which is why it's in a file with a big comment at the top.

**Remember:** *Many workers means many sets of numbers. Something must add them up.*

---

## Alert rules and the magic word `for:`

```yaml
- alert: DatabaseDown
  expr: database_up == 0
  for: 1m              # ← must stay broken for a full minute
```

Without `for:`, a two-second network blip wakes someone at 3am for a problem that already
fixed itself. Do that a few times and people start ignoring alerts — and then they ignore
the real one.

`scripts/chaos.sh` watches exactly this: `none → pending → firing` over ~70 seconds.

**Remember:** *`for:` is the difference between an alert and a nuisance. Alert fatigue kills people's trust.*

---

## Alert on ratios, not counts

```
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.05
```

50 errors out of 50,000 requests is a normal Tuesday. 50 errors out of 60 is an outage.
**The raw number is meaningless without the denominator.**

**Remember:** *Percentages scale. Counts don't.*

---

## Grafana and why the dashboard lives in git

You *could* click a dashboard together in Grafana's UI. Then it exists **only** in
Grafana's database — nobody else can reproduce it, and it vanishes when the container is recreated.

This one is a **file** (`monitoring/grafana/dashboards/*.json`) applied at startup. Delete the
Grafana volume, run `make up`, dashboard's still there.

This idea has a name — **Infrastructure as Code** — and it's the single biggest idea in
modern DevOps: *if it isn't written down in a file, it doesn't really exist.*

**Remember:** *Clicks vanish. Files survive. Anything you configured by clicking, you will lose.*

---

## Exporters

PostgreSQL speaks SQL. cAdvisor watches containers. Neither speaks Prometheus.

An **exporter** is a small translator that sits next to a thing and publishes its stats in
Prometheus's format. There's an exporter for almost everything.

**Remember:** *An exporter is a translator, not a monitor.*

---

# Part 5½ — The Four Bugs That Taught The Most

These are worth more than the features. Every one is a mistake you'll now never make.

### 1. Monitoring that went blind exactly when needed 🏆

**Symptom:** stopped the database, expected `DatabaseDown`. Got `ApiDown` instead, and the
database alert never fired at all.

**Cause:** `/metrics` ran a database query with no timeout. With the DB dead it hung 40+
seconds. Prometheus gives up at 10s and marked the whole API **down** — so `database_up`
was never recorded, so the alert about the database *couldn't* fire.

**The lesson — the most important one in this file:**
> **If your monitoring shares a failure mode with the thing it monitors, it goes blind exactly when you need it.**

A metrics endpoint must **never** block on a dependency. Stale numbers beat no numbers.

### 2. A health check that had been lying for days

`tt-web` showed **unhealthy** while the website worked perfectly.

nginx listens on IPv4 only. Inside the container, `localhost` resolves to **both**
`127.0.0.1` and `::1`, and wget tried IPv6 first → refused. **The probe was broken, not the server.**

Worse: nothing *asserted* container health, so it failed silently for days.

**Lesson:** *A broken health check is as dangerous as a broken service — it's what decides whether to restart a container or send it traffic. And anything you don't assert, you aren't checking.*

### 3. A test that was itself the bug

A security check "failed", reporting Postgres was exposed. It wasn't. The check grepped
text that contained the *container* port and matched the wrong number. Then `nc 127.0.0.1
5432` succeeded — which looked like confirmation, but was an unrelated Postgres installed
on the Mac.

**Lesson:** *A failing test may be wrong itself. Verify the finding before you "fix" the code. And always find out who owns a port before blaming your app.*

### 4. A race that only failed in CI

The smoke test queried Prometheus the instant targets came up. Locally: fine. In CI: no data.

Prometheus is **eventually consistent** — it pulls every 15s, so a value can be missing
simply because the next scrape hasn't happened yet.

**Lesson:** *"Works on my machine" applies to tests too. Anything eventually-consistent needs a wait, not an assumption.*

---

# Part 6 — Test Yourself (do this in a week)

Cover the answers. Retrieval is what builds memory — rereading feels productive and does almost nothing.

1. What are the three Docker words, in order?
2. Why does `COPY requirements.txt` come before `COPY app.py`?
3. What's wrong with `depends_on: [db]`?
4. What does the `-v` in `docker compose down -v` destroy?
5. Why does nginx exist if Flask can already serve pages?
6. What does `needs: unit` prevent in the pipeline?
7. A unit test passes but the container is broken. What catches it?
8. Does Prometheus push or pull? Why does that matter?
9. What's the difference between a counter and a gauge?
10. Why show p95 instead of the average?
11. Why must a task ID never be a metric label?
12. What does `for: 1m` prevent?
13. Why is a dashboard in the UI worse than a dashboard in git?
14. Why must `/metrics` never query the database without a timeout?

<details>
<summary>Answers</summary>

1. Dockerfile (recipe) → image (frozen meal) → container (dinner).
2. Layer caching — deps change rarely, code changes constantly. Wrong order = reinstall everything on every edit.
3. It waits for the container to *start*, not to be *ready*. Postgres accepts connections seconds later. Use `condition: service_healthy`.
4. The named volumes — your database data. A restart becomes a data wipe.
5. One front door. The app and DB publish no ports at all; nginx also serves static files and later handles HTTPS and load balancing.
6. Building and publishing an image from code that already failed its tests.
7. The integration/smoke test. Unit tests test your code; integration tests test your assumptions.
8. Pulls. It always knows when a target is unreachable (`up=0`) — with push, silence is ambiguous.
9. Counter only goes up (odometer). Gauge goes up and down (speedometer).
10. Averages hide the slow tail. 99 fast + 1 terrible still averages "fine" while 1% of users suffer.
11. Every label value is a permanent time series. Unbounded values can create millions and take Prometheus down.
12. Alerting on a momentary blip that already fixed itself — which causes alert fatigue, which makes people ignore the real one.
13. UI config exists only in Grafana's database: unreproducible, unreviewable, and gone when the container is recreated.
14. If the DB dies the scrape hangs, Prometheus times out, the target goes down, and you lose *every* metric at the exact moment you need them.

</details>

---

# Part 7 — Explain It In 60 Seconds (interview answer)

> "I built a three-tier app — nginx, a Flask API, and PostgreSQL — running on Docker
> Compose. Only nginx publishes a port; the app and database sit on separate internal
> networks, so the web tier can't even resolve the database hostname.
>
> Everything's health-checked, with `condition: service_healthy` for startup ordering, and
> the database uses a named volume so data survives restarts.
>
> CI runs unit tests first, then stands the whole stack up and runs 35 end-to-end checks,
> then a chaos drill that stops the database and asserts the alert actually fires.
>
> For monitoring I instrumented RED metrics plus a business metric, with Prometheus
> scraping and a Grafana dashboard provisioned from files so it's reproducible.
>
> The most interesting bug: the metrics endpoint queried the database with no timeout, so
> when the database died the scrape hung, Prometheus marked the target down, and I lost all
> telemetry exactly when I needed it. Fixed with a bounded timeout — and the chaos test now
> guarantees it can't regress."

That last paragraph is what gets you hired. **Anyone can list tools. Almost nobody can
describe a subtle failure they found and fixed.**

---

# Part 8 — The Nine Principles (the whole file, compressed)

1. **Write it down or it doesn't exist.** Clicks vanish; files survive.
2. **Started ≠ ready. Running ≠ working.** Always ask the thing a question.
3. **Fail cheap before you fail expensive.** Fast checks first.
4. **Never trust input.** Parameterise queries; validate at the edge.
5. **Secrets never enter git.** Git never forgets.
6. **Ship less.** Fewer programs, fewer ports, fewer permissions, smaller blast radius.
7. **Monitor the product, not just the machine.** The server can be perfectly healthy while nothing works.
8. **Your monitoring must not share a failure mode with what it monitors.**
9. **Anything you don't assert, you aren't checking.** A silent broken probe is worse than no probe.

---

## And the six words again

> **Write it → Prove it → Pack it → Wire it → Ship it → Watch it.**

Every tool you touched lives in exactly one of those six boxes. When you meet a new tool —
Terraform, Kubernetes, Alertmanager — the first useful question is always:
**"which of the six is this?"**

(Terraform = Wire it, for cloud servers. Kubernetes = Ship it + Wire it, at scale.
Alertmanager = Watch it, the part that actually wakes someone up.)

You're not learning 50 tools. You're learning 6 ideas that keep showing up wearing
different hats. 🚀
