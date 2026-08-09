#!/bin/sh
# SparkyFitness backend entrypoint for Railway.
#
# Boot order matters. Railway publishes the domain as soon as the deploy goes
# healthy, so an account has to exist BEFORE the server starts serving the port
# it will keep. Upstream ships signup OPEN and no admin, so a stock deploy is
# claimable by whoever loads the URL first. This script seeds the deployer's
# account on a throwaway listener, then re-execs the real server with signup
# disabled.
set -eu

log() { echo "[railway-entrypoint] $*"; }

: "${SPARKY_FITNESS_ADMIN_EMAIL:?SPARKY_FITNESS_ADMIN_EMAIL is required}"
if [ -z "${SPARKY_FITNESS_ADMIN_PASSWORD:-}" ]; then
  echo "[railway-entrypoint] FATAL: SPARKY_FITNESS_ADMIN_PASSWORD is empty." >&2
  echo "Refusing to boot an instance anyone could claim." >&2
  exit 1
fi
if [ "${#SPARKY_FITNESS_ADMIN_PASSWORD}" -lt 8 ]; then
  echo "[railway-entrypoint] FATAL: SPARKY_FITNESS_ADMIN_PASSWORD must be >= 8 chars." >&2
  exit 1
fi

UPLOADS_DIR="${SPARKY_FITNESS_CUSTOM_UPLOADS_DIRECTORY:-/data/uploads}"
BACKUP_DIR="${SPARKY_FITNESS_CUSTOM_BACKUP_DIRECTORY:-/data/backup}"
mkdir -p "$UPLOADS_DIR" "$BACKUP_DIR"
log "uploads=$UPLOADS_DIR backup=$BACKUP_DIR owner=$(stat -c %u:%g "$UPLOADS_DIR") uid=$(id -u)"

PORT_INTERNAL="${SPARKY_FITNESS_SERVER_PORT:-3010}"

users_exist() {
  PGPASSWORD="${SPARKY_FITNESS_DB_PASSWORD}" psql \
    -h "${SPARKY_FITNESS_DB_HOST}" -p "${SPARKY_FITNESS_DB_PORT:-5432}" \
    -U "${SPARKY_FITNESS_DB_USER}" -d "${SPARKY_FITNESS_DB_NAME}" \
    -tAc "SELECT count(*) FROM \"user\"" 2>/dev/null | tr -d '[:space:]'
}

COUNT="$(users_exist || true)"
if [ -n "$COUNT" ] && [ "$COUNT" != "0" ]; then
  log "existing accounts: $COUNT — skipping seed"
else
  log "no accounts yet — seeding ${SPARKY_FITNESS_ADMIN_EMAIL} on a private listener"
  SPARKY_FITNESS_DISABLE_SIGNUP=false \
  SPARKY_FITNESS_SERVER_PORT="$PORT_INTERNAL" \
    ./node_modules/.bin/tsx index.ts &
  SEED_PID=$!

  i=0
  until curl -sf "http://127.0.0.1:${PORT_INTERNAL}/api/health" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 180 ]; then
      log "FATAL: seed listener never became healthy"
      kill "$SEED_PID" 2>/dev/null || true
      exit 1
    fi
    kill -0 "$SEED_PID" 2>/dev/null || { log "FATAL: server exited during seed boot"; exit 1; }
    sleep 1
  done

  BODY=$(printf '{"email":"%s","password":"%s","name":"%s"}' \
    "$SPARKY_FITNESS_ADMIN_EMAIL" "$SPARKY_FITNESS_ADMIN_PASSWORD" "${SPARKY_FITNESS_ADMIN_NAME:-Admin}")
  CODE=$(curl -s -o /tmp/seed.out -w '%{http_code}' \
    -X POST "http://127.0.0.1:${PORT_INTERNAL}/api/auth/sign-up/email" \
    -H 'Content-Type: application/json' -d "$BODY" || echo 000)
  log "seed signup HTTP $CODE"
  if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
    log "seed response: $(head -c 300 /tmp/seed.out 2>/dev/null)"
  fi

  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  log "seed listener stopped"

  COUNT="$(users_exist || true)"
  if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
    log "FATAL: seeding produced no account; refusing to expose an open-signup instance"
    exit 1
  fi
fi

# Signup stays closed from here on. Additional users are invited from the admin
# panel; flip SPARKY_FITNESS_DISABLE_SIGNUP to false in the Railway variables
# if open registration is genuinely wanted.
export SPARKY_FITNESS_DISABLE_SIGNUP="${SPARKY_FITNESS_DISABLE_SIGNUP:-true}"
log "starting server (signup disabled=${SPARKY_FITNESS_DISABLE_SIGNUP}) on ${PORT_INTERNAL}"
exec ./node_modules/.bin/tsx index.ts
