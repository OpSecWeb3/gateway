#!/usr/bin/env bash
set -euo pipefail

# Gateway — Deploy Script (Hetzner VPS)
#
# Called by the deploy workflow via SSH. Copies nginx config,
# creates the shared Docker network, and starts/reloads nginx.
#
# TLS certs are delivered by CI pipeline (no SSM reads here).

GATEWAY_DIR="/opt/gateway"
REPO_DIR="$GATEWAY_DIR/repo"

cd "$REPO_DIR"

echo "==> Pulling latest gateway config..."
git fetch origin main
git checkout main
git reset --hard origin/main

# ── Copy config files to /opt/gateway ──────────────────────────────────────
echo "==> Syncing config files..."
cp "$REPO_DIR/docker-compose.yml" "$GATEWAY_DIR/docker-compose.yml"
cp -r "$REPO_DIR/nginx" "$GATEWAY_DIR/"

# ── TLS certs are delivered by CI pipeline to /opt/gateway/certs/ ────────
CERT_DIR="$GATEWAY_DIR/certs"
if [ ! -f "$CERT_DIR/origin.pem" ] || [ ! -f "$CERT_DIR/origin-key.pem" ]; then
  echo "==> WARN: TLS certs not found in $CERT_DIR. HTTPS won't work until certs are available."
fi

# ── Create shared Docker network ──────────────────────────────────────────
echo "==> Ensuring gateway network exists..."
docker network create gateway 2>/dev/null || true

# ── Start or reload nginx ─────────────────────────────────────────────────
cd "$GATEWAY_DIR"

if docker compose ps --status running nginx 2>/dev/null | grep -q nginx; then
  echo "==> Nginx is running — testing config and reloading..."
  docker compose exec -T nginx nginx -t
  docker compose exec -T nginx nginx -s reload
  echo "==> Nginx reloaded."
else
  echo "==> Starting nginx..."
  docker compose up -d
  echo "==> Nginx started."
fi

# ── Health check ──────────────────────────────────────────────────────────
echo "==> Checking nginx health..."
TRIES=0
MAX_TRIES=10
until curl -sf http://localhost/nginx-health > /dev/null 2>&1; do
  TRIES=$((TRIES + 1))
  if [ "$TRIES" -ge "$MAX_TRIES" ]; then
    echo "ERROR: Nginx health check failed after ${MAX_TRIES}s"
    docker compose logs --tail=20 nginx
    exit 1
  fi
  sleep 1
done

echo "==> Nginx is healthy."
echo "==> Gateway deploy complete."
