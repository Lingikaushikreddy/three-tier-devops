#!/usr/bin/env bash
# Integration test: drives the REAL stack through nginx, exactly like a user.
# Unit tests prove the functions work; this proves the system works.
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8080}"
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

echo
echo "================================"
echo "  passed: $PASS   failed: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ]
