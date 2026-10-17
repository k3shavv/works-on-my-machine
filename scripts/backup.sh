#!/bin/sh
# Runs inside the "backup" container (postgres:16-alpine).
#   backup.sh once   take one dump now
#   backup.sh loop   take a dump every BACKUP_INTERVAL_SECONDS (container default)
# Connection settings come from the standard PG* environment variables.
set -eu

BACKUP_DIR="${BACKUP_DIR:-/backups}"
KEEP="${BACKUP_KEEP:-7}"

backup_once() {
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  tmp="$BACKUP_DIR/.db-$ts.partial"
  out="$BACKUP_DIR/db-$ts.dump"
  # write to a temp name first, so a half-finished dump is never mistaken for a backup
  if ! pg_dump --format=custom --file="$tmp"; then
    rm -f "$tmp"   # don't leave debris behind when the database is unreachable
    return 1
  fi
  mv "$tmp" "$out"
  echo "{\"level\":\"INFO\",\"msg\":\"backup written\",\"file\":\"$out\"}"
  # keep only the newest $KEEP dumps
  ls -1t "$BACKUP_DIR"/db-*.dump | tail -n +"$((KEEP + 1))" | xargs -r rm -f --
}

case "${1:-once}" in
  once) backup_once ;;
  loop)
    while true; do
      backup_once || echo '{"level":"ERROR","msg":"backup failed"}'
      sleep "${BACKUP_INTERVAL_SECONDS:-3600}"
    done
    ;;
  *) echo "usage: backup.sh [once|loop]" >&2; exit 2 ;;
esac
