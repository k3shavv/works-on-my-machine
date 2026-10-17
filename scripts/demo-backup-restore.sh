#!/usr/bin/env bash
# Disaster-recovery demo: back up, destroy the data, restore, verify.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PROXY_PORT:-$(grep -E '^PROXY_PORT=' .env 2>/dev/null | cut -d= -f2 || true)}"
URL="http://127.0.0.1:${PORT:-8080}"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
post() { curl -s -X POST -H 'Content-Type: application/json' -d "{\"text\":\"$1\"}" "$URL/notes"; echo; }

say "1. add a note we will care about"
post "important-data-$(date +%s)"
curl -s "$URL/notes"; echo

say "2. take a backup right now"
docker compose exec -T backup /bin/sh /scripts/backup.sh once
ls -lh backups | tail -3

say "3. DISASTER: drop the notes table"
docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP TABLE notes"'
echo "   what the app returns now (first call errors, the app then recreates an EMPTY table):"
curl -s -o /dev/null -w '   GET /notes -> %{http_code}\n' "$URL/notes" || true
curl -s "$URL/notes"; echo

say "4. restore the newest backup"
./scripts/restore.sh

say "5. verify the data is back"
sleep 3
curl -s "$URL/notes"; echo
