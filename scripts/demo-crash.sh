#!/usr/bin/env bash
# Failure demo. Needs the stack running with ENABLE_CHAOS=true (the default in
# .env.example). While breaking things it sends steady traffic through nginx
# and prints how many requests succeeded.
#   scripts/demo-crash.sh            run all three scenarios
#   scripts/demo-crash.sh crash      only scenario 1
#   scripts/demo-crash.sh sick       only scenario 2
#   scripts/demo-crash.sh db         only scenario 3
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PROXY_PORT:-$(grep -E '^PROXY_PORT=' .env 2>/dev/null | cut -d= -f2 || true)}"
URL="http://127.0.0.1:${PORT:-8080}"
LOG="$(mktemp)"
TRAFFIC_PID=""

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

start_traffic() {
  : > "$LOG"
  ( while true; do
      curl -s -o /dev/null --max-time 3 -w '%{http_code}\n' "$URL/notes" >> "$LOG" || echo "000" >> "$LOG"
      sleep 0.1
    done ) &
  TRAFFIC_PID=$!
}

stop_traffic() {
  [ -n "$TRAFFIC_PID" ] && kill "$TRAFFIC_PID" 2>/dev/null || true
  TRAFFIC_PID=""
  echo "   requests sent through nginx during the test, by HTTP status:"
  sort "$LOG" | uniq -c | sed 's/^/     /'
}
trap 'stop_traffic >/dev/null 2>&1 || true' EXIT

# call an /admin endpoint from INSIDE a container (nginx blocks it from outside)
admin_post() {  # <container-id> <path>
  docker exec "$1" python -c "
import urllib.request, urllib.error
try:
    urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000$2', method='POST'), timeout=3)
except urllib.error.HTTPError as e:
    print('HTTP', e.code)
except Exception as e:
    print('connection closed:', type(e).__name__)
"
}

health() { docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo gone; }
# StartedAt changes on EVERY restart. (RestartCount only counts restarts done by the
# restart policy, not the ones autoheal does with `docker restart`.)
started() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || echo gone; }

wait_for_recovery() {  # <container-id> <StartedAt-before>
  local id="$1" before="$2" start=$SECONDS
  while [ $((SECONDS - start)) -lt 60 ]; do
    local st h; st="$(started "$id")"; h="$(health "$id")"
    printf '   t+%02ds health=%-9s %s\n' $((SECONDS - start)) "$h" \
      "$([ "$st" != "$before" ] && echo "(restarted)" || echo "(same process)")"
    if [ "$st" != "$before" ] && [ "$h" = "healthy" ]; then
      echo "   -> recovered by itself after $((SECONDS - start))s"; return 0
    fi
    sleep 2
  done
  echo "   -> did NOT recover within 60s"; return 1
}

# make sure the chaos endpoints are switched on
check_chaos() {
  local id; id="$(docker compose ps -q app | head -1)"
  [ -n "$id" ] || { echo "The app is not running. Start it with: make up"; exit 1; }
  if docker exec "$id" python -c "
import urllib.request, urllib.error, sys
try: urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000/admin/heal', method='POST'), timeout=3)
except urllib.error.HTTPError: sys.exit(1)
"; then return 0; fi
  echo "ENABLE_CHAOS is not true. Set ENABLE_CHAOS=true in .env and run: make up"; exit 1
}

scenario_crash() {
  say "Scenario 1: an app container CRASHES (process exits)"
  local victim; victim="$(docker compose ps -q app | head -1)"
  local before; before="$(started "$victim")"
  start_traffic
  sleep 1
  echo "   killing the process inside ${victim:0:12}"
  admin_post "$victim" /admin/crash || true
  wait_for_recovery "$victim" "$before" || true
  sleep 2
  stop_traffic
}

scenario_sick() {
  say "Scenario 2: an app container turns UNHEALTHY (process alive, /healthz returns 500)"
  local victim; victim="$(docker compose ps -q app | head -1)"
  local before; before="$(started "$victim")"
  start_traffic
  sleep 1
  admin_post "$victim" /admin/sicken
  echo "   Docker marks it unhealthy after 3 failed checks, then 'autoheal' restarts it"
  wait_for_recovery "$victim" "$before" || true
  sleep 2
  stop_traffic
}

scenario_db() {
  say "Scenario 3: the DATABASE container is killed"
  local db_id; db_id="$(docker compose ps -q db)"
  start_traffic
  sleep 1
  docker kill "$db_id" >/dev/null
  echo "   db killed, docker's restart policy brings it back; the app stays up and returns 503 meanwhile"
  local start=$SECONDS
  until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL/readyz")" = "200" ]; do
    [ $((SECONDS - start)) -gt 60 ] && { echo "   -> app did not recover"; break; }
    sleep 2
  done
  echo "   -> /readyz is 200 again after $((SECONDS - start))s, no app restart was needed"
  sleep 2
  stop_traffic
  echo "   data check, notes still there:"
  curl -s "$URL/notes" | head -c 300; echo
}

check_chaos
case "${1:-all}" in
  crash) scenario_crash ;;
  sick)  scenario_sick ;;
  db)    scenario_db ;;
  all)   scenario_crash; scenario_sick; scenario_db ;;
  *)     echo "usage: $0 [crash|sick|db|all]"; exit 2 ;;
esac
