#!/usr/bin/env bash
set -euo pipefail

# Shared Infra — Deploy Script (Hetzner VPS)
#
# Called by the deploy workflow via SSH. Syncs config, ensures the shared
# Docker networks exist, and starts/reloads the nginx + postgres + redis stack.
#
# Secrets (.env) and TLS certs are delivered by CI before this runs.

SHARED_DIR="/opt/shared"
REPO_DIR="$SHARED_DIR/repo"

cd "$REPO_DIR"

echo "==> Pulling latest config..."
git fetch origin main
git checkout main
git reset --hard origin/main

# ── Sync config files to /opt/shared ───────────────────────────────────────
echo "==> Syncing config files..."
cp "$REPO_DIR/docker-compose.yml" "$SHARED_DIR/docker-compose.yml"
rm -rf "$SHARED_DIR/nginx"
cp -r "$REPO_DIR/nginx" "$SHARED_DIR/"

# ── Ensure .env is present (delivered by CI) ──────────────────────────────
if [ ! -f "$SHARED_DIR/.env" ]; then
  echo "ERROR: .env not found in $SHARED_DIR. CI should have delivered it."
  exit 1
fi

# Load creds for health checks below.
# shellcheck disable=SC1091
set -a; . "$SHARED_DIR/.env"; set +a

# ── TLS certs (delivered by CI to /opt/shared/certs/) ─────────────────────
CERT_DIR="$SHARED_DIR/certs"
if [ ! -f "$CERT_DIR/origin.pem" ] || [ ! -f "$CERT_DIR/origin-key.pem" ]; then
  echo "==> WARN: TLS certs not found in $CERT_DIR. HTTPS won't work until certs are available."
fi

# ── Ensure external Docker networks exist ─────────────────────────────────
echo "==> Ensuring shared networks exist..."
docker network create gateway 2>/dev/null || true
docker network create shared-infra 2>/dev/null || true

cd "$SHARED_DIR"

# ── Start or reload the stack ─────────────────────────────────────────────
echo "==> Bringing up shared stack..."
docker compose up -d --remove-orphans

# Reload nginx config in place (picks up conf.d edits without dropping conns).
if docker compose exec -T nginx nginx -t 2>/dev/null; then
  docker compose exec -T nginx nginx -s reload || true
  echo "==> Nginx reloaded."
fi

# ── Health checks ─────────────────────────────────────────────────────────
wait_for() {
  local name=$1; shift
  local tries=0 max=15
  until "$@" > /dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      echo "ERROR: ${name} health check failed after ${max} attempts"
      docker compose logs --tail=20 "$name" || true
      exit 1
    fi
    sleep 2
  done
  echo "==> ${name} is healthy."
}

echo "==> Checking nginx health..."
wait_for nginx curl -sf http://localhost/nginx-health

echo "==> Checking postgres health..."
wait_for postgres docker compose exec -T postgres pg_isready -U "$POSTGRES_USER"

echo "==> Checking redis health..."
wait_for redis docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" ping

echo "==> Shared infra deploy complete."
docker compose ps
