#!/usr/bin/env bash
set -euo pipefail

# Shared Postgres — Backup Script
#
# Usage:   ./scripts/backup-db.sh [DB_NAME]
# Crontab: 0 3 * * * /opt/shared/repo/scripts/backup-db.sh sentinel >> /var/log/shared-backup.log 2>&1
#
# Dumps one database via the running postgres container, gzips it into
# BACKUP_DIR, and prunes backups older than RETENTION_DAYS.

SHARED_DIR="/opt/shared"
BACKUP_DIR="${BACKUP_DIR:-$SHARED_DIR/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DB_NAME="${1:-${POSTGRES_DB:-sentinel}}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILENAME="${DB_NAME}_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

# Load creds from the deployed .env
# shellcheck disable=SC1091
set -a; . "$SHARED_DIR/.env"; set +a

echo "[$(date -Iseconds)] Starting backup of '${DB_NAME}'..."

docker compose -f "$SHARED_DIR/docker-compose.yml" exec -T postgres pg_dump \
  -U "$POSTGRES_USER" \
  -d "$DB_NAME" \
  --no-owner \
  --no-acl \
  | gzip > "${BACKUP_DIR}/${FILENAME}"

SIZE=$(du -h "${BACKUP_DIR}/${FILENAME}" | cut -f1)
echo "[$(date -Iseconds)] Backup complete: ${FILENAME} (${SIZE})"

# ── Prune old backups ─────────────────────────────────────────────────────
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +"$RETENTION_DAYS" -print -delete
