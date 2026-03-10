#!/usr/bin/env bash
set -euo pipefail

# Gateway — Deploy Script (runs on EC2 via SSM)
#
# Copies nginx config to /opt/gateway, ensures certs exist,
# creates the shared Docker network, and starts/reloads nginx.
#
# Certs are written by chainalert's deploy.sh (it fetches from SSM
# and copies to /opt/gateway/certs/). On first gateway deploy before
# chainalert, this script can fetch them directly from SSM.

GATEWAY_DIR="/opt/gateway"
REPO_DIR="$GATEWAY_DIR/repo"

# ── Resolve AWS region from instance metadata ─────────────────────────────
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "eu-west-2")

# ── Fetch GitHub App token from SSM ───────────────────────────────────────
GH_TOKEN=$(aws ssm get-parameter \
  --name "/chainalert/production/GH_APP_TOKEN" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

# ── Clone or update repo ──────────────────────────────────────────────────
if [ ! -d "$REPO_DIR" ]; then
  echo "==> First deploy: cloning gateway repo..."
  if [ -z "$GH_TOKEN" ]; then
    echo "ERROR: No GitHub App token found in SSM. Cannot clone repo."
    exit 1
  fi
  git clone "https://x-access-token:${GH_TOKEN}@github.com/OpSecWeb3/gateway.git" "$REPO_DIR"
fi

cd "$REPO_DIR"

echo "==> Pulling latest gateway config..."
if [ -n "$GH_TOKEN" ]; then
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/OpSecWeb3/gateway.git"
fi
git fetch origin main
git checkout main
git reset --hard origin/main
git remote set-url origin "https://github.com/OpSecWeb3/gateway.git"

# ── Copy config files to /opt/gateway ──────────────────────────────────────
echo "==> Syncing config files..."
cp "$REPO_DIR/docker-compose.yml" "$GATEWAY_DIR/docker-compose.yml"
cp -r "$REPO_DIR/nginx" "$GATEWAY_DIR/"

# ── Ensure certs exist ────────────────────────────────────────────────────
CERT_DIR="$GATEWAY_DIR/certs"
mkdir -p "$CERT_DIR"

if [ ! -f "$CERT_DIR/origin.pem" ] || [ ! -f "$CERT_DIR/origin-key.pem" ]; then
  echo "==> No certs found — fetching from SSM..."
  ORIGIN_CERT=$(aws ssm get-parameter \
    --name "/chainalert/production/CLOUDFLARE_ORIGIN_CERT" \
    --with-decryption --query "Parameter.Value" --output text \
    --region "$REGION" 2>/dev/null || echo "")

  ORIGIN_KEY=$(aws ssm get-parameter \
    --name "/chainalert/production/CLOUDFLARE_ORIGIN_KEY" \
    --with-decryption --query "Parameter.Value" --output text \
    --region "$REGION" 2>/dev/null || echo "")

  if [ -n "$ORIGIN_CERT" ] && [ -n "$ORIGIN_KEY" ]; then
    echo "$ORIGIN_CERT" > "$CERT_DIR/origin.pem"
    echo "$ORIGIN_KEY" > "$CERT_DIR/origin-key.pem"
    chmod 600 "$CERT_DIR/origin-key.pem"
    echo "==> TLS certs written from SSM."
  else
    echo "==> WARN: No certs in SSM. Gateway will start but HTTPS won't work"
    echo "==>       until chainalert deploys and writes certs."
  fi
else
  echo "==> TLS certs already present."
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
