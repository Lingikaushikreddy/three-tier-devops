#!/usr/bin/env bash
# Failure drill: break the database on purpose and assert the system behaves.
#
# Monitoring you have never seen fire is a guess. This script proves:
#   1. the app degrades honestly instead of lying about being healthy
#   2. the OBSERVABILITY survives the outage (the hard part)
#   3. the alert actually reaches "firing"
#   4. everything recovers when the dependency comes back
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:8080}"
PROM="${PROM:-http://127.0.0.1:9090}"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS  $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}
status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
prom_value() {
  curl -fsS "$PROM/api/v1/query?query=$1" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nodata")'
}
target_health() {
  curl -fsS "$PROM/api/v1/targets" \
    | python3 -c 'import json,sys; print(next((t["health"] for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"]["job"]=="api"), "missing"))'
}
alert_state() {
  curl -fsS "$PROM/api/v1/alerts" \
    | python3 -c "import json,sys; print(next((a['state'] for a in json.load(sys.stdin)['data']['alerts'] if a['labels']['alertname']=='$1'), 'none'))"
}

echo "=== baseline ==="
check "stack is healthy to begin with" "200" "$(status_of "$BASE/health")"
BEFORE=$(curl -fsS "$BASE/api/tasks" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
echo "  (tasks before the outage: $BEFORE)"

echo
echo "=== injecting failure: stopping the database ==="
docker compose stop db >/dev/null 2>&1
sleep 3

check "/health degrades to 503"            "503" "$(status_of "$BASE/health")"
check "nginx itself stays up"              "200" "$(status_of "$BASE/nginx-health")"
check "static page still served"           "200" "$(status_of "$BASE/")"

# THE REGRESSION TEST.
# /metrics used to query the database with no timeout. When the database died,
# the scrape hung for 40s, Prometheus gave up at 10s, and the API target went
# DOWN -- so every metric vanished at the exact moment we needed them. The fix
# was a bounded query timeout. This asserts it stays fixed.
echo
echo "=== the important part: is monitoring still working? ==="
START=$(python3 -c 'import time; print(time.time())')
METRICS_CODE=$(docker compose exec -T api python -c 'import urllib.request; print(urllib.request.urlopen("http://localhost:8000/metrics", timeout=8).status)' 2>/dev/null | tr -d '\r')
ELAPSED=$(python3 -c "import time; print(int(time.time() - $START))")
check "/metrics still answers with the DB down"  "200" "$METRICS_CODE"
if [ "$ELAPSED" -lt 5 ]; then
  echo "  PASS  /metrics answered in ${ELAPSED}s (must stay under the 10s scrape timeout)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  /metrics took ${ELAPSED}s - Prometheus will time out and lose the target"
  FAIL=$((FAIL + 1))
fi

sleep 20 # let a scrape or two land
check "prometheus still scrapes the api"  "up" "$(target_health)"
check "database_up reports 0"             "0"  "$(prom_value 'database_up')"

echo
echo "=== waiting for DatabaseDown to fire (for: 1m) ==="
FIRED=no
for i in $(seq 1 30); do
  st=$(alert_state DatabaseDown)
  printf "  t=%ss  DatabaseDown=%s\n" "$((i * 5))" "$st"
  if [ "$st" = "firing" ]; then FIRED=yes; break; fi
  sleep 5
done
check "DatabaseDown reached firing" "yes" "$FIRED"

echo
echo "=== recovery: starting the database ==="
docker compose start db >/dev/null 2>&1
RECOVERED=no
for i in $(seq 1 60); do
  if [ "$(status_of "$BASE/health")" = "200" ]; then RECOVERED=yes; echo "  /health back to 200 after ~${i}s"; break; fi
  sleep 1
done
check "the app recovered on its own" "yes" "$RECOVERED"
check "no data was lost"             "$BEFORE" "$(curl -fsS "$BASE/api/tasks" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')"

CLEARED=no
for i in $(seq 1 24); do
  st=$(alert_state DatabaseDown)
  if [ "$st" = "none" ]; then CLEARED=yes; echo "  DatabaseDown cleared after ~$((i * 5))s"; break; fi
  sleep 5
done
check "DatabaseDown resolved itself" "yes" "$CLEARED"

echo
echo "================================"
echo "  passed: $PASS   failed: $FAIL"
echo "================================"
# Note: HighErrorRate / HighLatencyP95 may sit in 'pending' for a few more
# minutes -- rate() still has the outage inside its 5m window. That is correct.
[ "$FAIL" -eq 0 ]
