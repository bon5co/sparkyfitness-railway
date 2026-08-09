#!/bin/bash
# SparkyFitness frontend entrypoint for Railway.
#
# nginx resolves proxy_pass hostnames once, at startup, because envsubst turns
# the backend host into a literal. On Railway the private DNS name only answers
# once the backend service has an address, so a cold deploy can lose the race
# and nginx exits with "host not found in upstream". Wait for the name first.
set -e

export NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-${PORT:-8080}}"
export SPARKY_FITNESS_SERVER_HOST="${SPARKY_FITNESS_SERVER_HOST:-sparkyfitness-server}"
export SPARKY_FITNESS_SERVER_PORT="${SPARKY_FITNESS_SERVER_PORT:-3010}"

echo "[railway-entrypoint] listen=${NGINX_LISTEN_PORT} backend=${SPARKY_FITNESS_SERVER_HOST}:${SPARKY_FITNESS_SERVER_PORT}"

i=0
until getent ahosts "${SPARKY_FITNESS_SERVER_HOST}" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 120 ]; then
    echo "[railway-entrypoint] FATAL: ${SPARKY_FITNESS_SERVER_HOST} never resolved" >&2
    exit 1
  fi
  [ $((i % 10)) -eq 1 ] && echo "[railway-entrypoint] waiting for ${SPARKY_FITNESS_SERVER_HOST} to resolve..."
  sleep 1
done
echo "[railway-entrypoint] backend resolved after ${i}s"

# Upstream's entrypoint envsubst's a fixed list of variables, so the resolver
# address cannot ride along as one — substitute it here instead.
NGINX_RESOLVER="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)"
case "$NGINX_RESOLVER" in
  *:*) NGINX_RESOLVER="[${NGINX_RESOLVER}]" ;;   # bracket IPv6 for nginx
  '')  NGINX_RESOLVER='127.0.0.11' ;;
esac
echo "[railway-entrypoint] nginx resolver=${NGINX_RESOLVER}"
sed -i "s|__NGINX_RESOLVER__|${NGINX_RESOLVER}|g" /etc/nginx/templates/default.conf.template

exec /docker-entrypoint.sh
