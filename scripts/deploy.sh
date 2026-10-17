#!/usr/bin/env bash
# Rolling update with automatic rollback.
#   scripts/deploy.sh <image-tag>        e.g. a git sha, or "v2"
#
# How it avoids downtime:
#   1. start N NEW replicas next to the N old ones
#   2. wait until every new replica reports healthy
#   3. only then stop the old ones (nginx keeps sending traffic to whoever is up)
# If the new replicas never become healthy they are removed and the old ones
# are left running, so a bad release never takes the site down.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/deploy.sh <image-tag>}"
REPLICAS="${APP_REPLICAS:-$(grep -E '^APP_REPLICAS=' .env 2>/dev/null | cut -d= -f2 || true)}"
REPLICAS="${REPLICAS:-2}"
TIMEOUT="${DEPLOY_TIMEOUT:-90}"
export APP_TAG="$TAG"

dc() { docker compose "$@"; }

echo "==> getting image for tag '$TAG' (registry first, local build as fallback)"
dc pull --quiet app 2>/dev/null || dc build app

old_ids="$(dc ps -q app)"
if [ -z "$old_ids" ]; then
  echo "==> nothing running yet, doing a normal first start"
  dc up -d --wait
  exit 0
fi

echo "==> starting $REPLICAS new replica(s) alongside the old ones"
dc up -d --no-deps --no-recreate --scale app="$((REPLICAS * 2))" app

new_ids="$(dc ps -q app | grep -vxF -f <(echo "$old_ids") || true)"
if [ -z "$new_ids" ]; then
  echo "!! no new containers were created, aborting"
  exit 1
fi
new_count="$(echo "$new_ids" | wc -w)"

echo "==> waiting up to ${TIMEOUT}s for the new replicas to become healthy"
deadline=$((SECONDS + TIMEOUT))
while :; do
  healthy=0
  for id in $new_ids; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || echo gone)"
    [ "$status" = "healthy" ] && healthy=$((healthy + 1))
  done
  echo "    $healthy/$new_count healthy"
  [ "$healthy" -eq "$new_count" ] && break
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "!! new replicas did not become healthy in ${TIMEOUT}s, ROLLING BACK"
    echo "$new_ids" | xargs docker logs --tail 20 2>&1 | sed 's/^/    /' || true
    for id in $new_ids; do docker rm -f "$id" >/dev/null; done
    echo "!! old version is still serving traffic"
    exit 1
  fi
  sleep 2
done

echo "==> new replicas healthy, draining the old ones"
for id in $old_ids; do
  docker stop -t 25 "$id" >/dev/null   # SIGTERM: gunicorn finishes in-flight requests
  docker rm "$id" >/dev/null
done

# remember the tag, so a later `docker compose up` keeps this version,
# and keep a history so rollback is "deploy the previous tag"
if grep -q '^APP_TAG=' .env 2>/dev/null; then
  sed -i "s/^APP_TAG=.*/APP_TAG=$TAG/" .env
else
  echo "APP_TAG=$TAG" >> .env
fi
echo "$(date -u +%FT%TZ) $TAG" >> .deploy-history

echo "==> deployed $TAG"
dc ps app
