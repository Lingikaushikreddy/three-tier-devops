#!/usr/bin/env bash
# Integration test: drives the REAL stack through nginx, exactly like a user.
# Unit tests prove the functions work; this proves the system works.
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8080}"
PROM="${PROM:-http://127.0.0.1:9090}"
GRAF="${GRAF:-http://127.0.0.1:3000}"
GRAF_AUTH="${GRAF_AUTH:-admin:admin}"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "Waiting for the stack at $BASE ..."
for i in $(seq 1 60); do
  # Deliberately not --retry-connrefused: a booting container ACCEPTS the
  # connection and then RESETS it, which that flag does not retry.
  if curl -fsS "$BASE/health" >/dev/null 2>&1; then
    echo "Stack is up after ${i}s."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "Stack never became healthy. Logs:"
    docker compose logs --tail=40
    exit 1
  fi
  sleep 1
done

echo
echo "--- tier 1: nginx ---"
check "nginx answers its own health check" "200" "$(status_of "$BASE/nginx-health")"
check "static page is served"              "200" "$(status_of "$BASE/")"

echo "--- tier 2 + 3: api and database ---"
check "/health is 200"                     "200" "$(status_of "$BASE/health")"
if curl -fsS "$BASE/health" | grep -q '"database":"connected"'; then
  echo "  PASS  api reports the database is connected"; PASS=$((PASS + 1))
else
  echo "  FAIL  api does not report a connected database"; FAIL=$((FAIL + 1))
fi

check "seed data was loaded"               "200" "$(status_of "$BASE/api/tasks")"
SEEDED=$(curl -fsS "$BASE/api/tasks" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"] >= 4)')
check "at least 4 seeded tasks"            "True" "$SEEDED"

echo "--- full CRUD cycle through the proxy ---"
CREATED=$(curl -fsS -X POST "$BASE/api/tasks" \
  -H 'Content-Type: application/json' \
  -d '{"title":"smoke test task"}')
ID=$(echo "$CREATED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
check "create returns an id"  "True" "$([ -n "$ID" ] && echo True || echo False)"

check "read it back"          "200" "$(status_of "$BASE/api/tasks/$ID")"

DONE=$(curl -fsS -X PATCH "$BASE/api/tasks/$ID" \
  -H 'Content-Type: application/json' -d '{"done":true}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["done"])')
check "mark it done"          "True" "$DONE"

check "delete it"             "204" "$(status_of -X DELETE "$BASE/api/tasks/$ID")"
check "it is gone"            "404" "$(status_of "$BASE/api/tasks/$ID")"

echo "--- input validation ---"
check "empty title rejected"     "400" "$(status_of -X POST "$BASE/api/tasks" -H 'Content-Type: application/json' -d '{"title":""}')"
check "missing title rejected"   "400" "$(status_of -X POST "$BASE/api/tasks" -H 'Content-Type: application/json' -d '{}')"
check "numeric title rejected"   "400" "$(status_of -X POST "$BASE/api/tasks" -H 'Content-Type: application/json' -d '{"title":123}')"
check "overlong title rejected"  "400" "$(status_of -X POST "$BASE/api/tasks" -H 'Content-Type: application/json' -d "{\"title\":\"$(printf 'x%.0s' {1..201})\"}")"
check "unknown task is 404"      "404" "$(status_of "$BASE/api/tasks/99999999")"

echo "--- security: the lower tiers must not be exposed ---"
# Ask Docker directly which HOST ports a container binds. Do not grep the
# `docker compose ps` text: it prints the CONTAINER port too, so a naive
# grep for 5432 matches even when nothing is published. (Learned the hard way.)
host_ports_of() {
  docker inspect --format '{{json .NetworkSettings.Ports}}' "$1" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin) or {}; print(sum(1 for v in d.values() if v))'
}

check "postgres binds no host port" "0" "$(host_ports_of tt-db)"
check "api binds no host port"      "0" "$(host_ports_of tt-api)"

# Network segmentation: the web tier is only on `frontend`, the database only
# on `backend`, so nginx cannot even RESOLVE the name "db".
if docker compose exec -T web sh -c 'nc -z -w 3 db 5432' >/dev/null 2>&1; then
  echo "  FAIL  the web tier can reach the database directly"; FAIL=$((FAIL + 1))
else
  echo "  PASS  the web tier cannot reach the database (networks are segmented)"
  PASS=$((PASS + 1))
fi

echo "--- observability: prometheus ---"

# Wait for the monitoring tier the same way we waited for the app. Prometheus
# and Grafana boot AFTER the api is healthy, so a test that starts querying
# them immediately is a flaky test, not a failing stack.
wait_for() {
  local name="$1" url="$2"
  for _ in $(seq 1 60); do
    curl -fsS "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  FAIL  $name never became ready at $url"
  FAIL=$((FAIL + 1))
  return 1
}

wait_for "prometheus" "$PROM/-/healthy"
wait_for "grafana" "$GRAF/api/health"

# Prometheus needs at least one scrape cycle before it has anything to serve.
for _ in $(seq 1 40); do
  scraped=$(curl -fsS "$PROM/api/v1/targets" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["activeTargets"]; print(sum(1 for t in d if t["health"]=="up"))' 2>/dev/null || echo 0)
  [ "${scraped:-0}" -ge 4 ] && break
  sleep 2
done

check "prometheus is healthy" "200" "$(status_of "$PROM/-/healthy")"

# Every scrape target must be UP. A target that is DOWN means you are blind to
# that component, which is worse than having no dashboard at all.
TARGETS_DOWN=$(curl -fsS "$PROM/api/v1/targets" \
  | python3 -c 'import json,sys; print(sum(1 for t in json.load(sys.stdin)["data"]["activeTargets"] if t["health"]!="up"))')
check "no scrape target is down" "0" "$TARGETS_DOWN"

TARGET_COUNT=$(curl -fsS "$PROM/api/v1/targets" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["activeTargets"]))')
check "all 4 targets are registered" "4" "$TARGET_COUNT"

RULE_COUNT=$(curl -fsS "$PROM/api/v1/rules" \
  | python3 -c 'import json,sys; print(sum(len(g["rules"]) for g in json.load(sys.stdin)["data"]["groups"]))')
check "alert rules are loaded" "6" "$RULE_COUNT"

FIRING=$(curl -fsS "$PROM/api/v1/alerts" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["alerts"]))')
check "no alerts are firing on a healthy stack" "0" "$FIRING"

# Prometheus must have actually INGESTED our app metrics, not merely reached
# the target. A 200 from /metrics proves nothing about what is in the database.
HAS_METRIC=$(curl -fsS "$PROM/api/v1/query?query=http_requests_total" \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["result"]) > 0)')
check "app metrics reached prometheus" "True" "$HAS_METRIC"

DB_GAUGE=$(curl -fsS "$PROM/api/v1/query?query=database_up" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "missing")')
check "database_up reports 1" "1" "$DB_GAUGE"

echo "--- observability: grafana ---"
# Provisioning runs just after Grafana reports healthy; give it a moment.
for _ in $(seq 1 30); do
  curl -fsS -u "$GRAF_AUTH" "$GRAF/api/search?type=dash-db" 2>/dev/null | grep -q "three-tier-overview" && break
  sleep 2
done

check "grafana is healthy" "200" "$(status_of "$GRAF/api/health")"

DS=$(curl -fsS -u "$GRAF_AUTH" "$GRAF/api/datasources" \
  | python3 -c 'import json,sys; print(sum(1 for d in json.load(sys.stdin) if d["type"]=="prometheus"))')
check "prometheus datasource was provisioned" "1" "$DS"

# Provisioning is the point: the dashboard must exist without anyone clicking.
DASH=$(curl -fsS -u "$GRAF_AUTH" "$GRAF/api/search?type=dash-db" \
  | python3 -c 'import json,sys; print(sum(1 for d in json.load(sys.stdin) if d["uid"]=="three-tier-overview"))')
check "dashboard was provisioned from file" "1" "$DASH"

# A datasource can be "configured" and still not work. Ask Grafana to query it.
DS_OK=$(curl -fsS -u "$GRAF_AUTH" "$GRAF/api/datasources/uid/prometheus/health" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo FAIL)
check "grafana can actually query prometheus" "OK" "$DS_OK"

echo "--- observability: correctness ---"
# /metrics exposes internal route names, traffic volume and latency. It must
# not be reachable from outside, even though Prometheus reaches it internally.
check "metrics are NOT exposed through nginx" "404" "$(status_of "$BASE/metrics")"

# gunicorn runs 2 workers. Without prometheus_client's multiprocess mode each
# worker keeps its own counters and consecutive scrapes bounce between them,
# making the counter appear to go DOWN. Prometheus reads that as a restart.
# Fetch the raw /metrics text once, then parse it on the host. Keeping the
# in-container python single-quoted avoids the quoting trap of nesting double
# quotes inside a double-quoted shell string.
metrics_body() {
  docker compose exec -T api python -c 'import urllib.request; print(urllib.request.urlopen("http://localhost:8000/metrics").read().decode())'
}

read_counter() {
  metrics_body | python3 -c '
import re, sys
body = sys.stdin.read()
values = re.findall(r"^http_requests_total\{[^}]*\} ([0-9.e+]+)$", body, re.M)
print(int(sum(float(v) for v in values)))
'
}

for _ in $(seq 1 12); do curl -fsS "$BASE/health" >/dev/null 2>&1 || true; done
C1=$(read_counter)
for _ in $(seq 1 12); do curl -fsS "$BASE/health" >/dev/null 2>&1 || true; done
C2=$(read_counter)
if [ -n "$C1" ] && [ -n "$C2" ] && [ "$C2" -ge "$C1" ]; then
  echo "  PASS  request counter never decreases across workers ($C1 -> $C2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  counter went backwards ($C1 -> $C2) - multiprocess mode is broken"
  FAIL=$((FAIL + 1))
fi

if [ "${C2:-0}" -gt "${C1:-0}" ]; then
  echo "  PASS  the counter is actually recording traffic ($C1 -> $C2)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  counter did not move despite 12 requests"
  FAIL=$((FAIL + 1))
fi

# High-cardinality guard: /api/tasks/7 and /api/tasks/8 must collapse into one
# series, or every task id you ever create becomes a permanent time series.
curl -fsS "$BASE/api/tasks/1" >/dev/null 2>&1 || true
curl -fsS "$BASE/api/tasks/2" >/dev/null 2>&1 || true
CARD=$(metrics_body | python3 -c '
import re, sys
endpoints = set(re.findall(r"http_requests_total\{endpoint=\"([^\"]+)\"", sys.stdin.read()))
print(sum(1 for e in endpoints if re.search(r"/\d+$", e)))
')
check "no raw ids leaked into metric labels" "0" "$CARD"

echo
echo "================================"
echo "  passed: $PASS   failed: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ]
