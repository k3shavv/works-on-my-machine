#!/usr/bin/env bash
# Restore the database from a dump made by the backup service.
#   scripts/restore.sh                      restore the newest dump in ./backups
#   scripts/restore.sh backups/db-XXXX.dump restore a specific one
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:-$(ls -1t backups/db-*.dump 2>/dev/null | head -1 || true)}"
[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "No dump found. Pass a file: scripts/restore.sh backups/db-XXXX.dump"; exit 1; }

echo "==> restoring from $FILE"
echo "==> stopping the app so nothing writes during the restore"
docker compose stop app

# --clean --if-exists drops each object before recreating it, so this also works
# on a database where tables were deleted or damaged.
docker compose exec -T db sh -c \
  'pg_restore --clean --if-exists --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$FILE"

echo "==> starting the app again"
docker compose up -d --wait app
echo "==> restore finished"
