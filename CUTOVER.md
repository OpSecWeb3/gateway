# Cutover Runbook — chainalert → shared infra

One-time migration to consolidate nginx + postgres + redis into this repo
under project name `shared`, and spin down the chainalert project.

Estimated downtime for sentinel: ~5 minutes (volume copy + redeploy).

## Pre-flight (do before the window)

### 1. Copy SSM parameters to `/shared/production/*`

Keep the existing credentials so the copied postgres volume keeps working
and sentinel's `DATABASE_URL` doesn't need changing.

```bash
# Replace REGION with the CI region.
REGION=us-east-1
copy_param() {
  local src=$1 dst=$2
  local val
  val=$(aws ssm get-parameter --region "$REGION" --name "$src" --with-decryption --query 'Parameter.Value' --output text)
  aws ssm put-parameter --region "$REGION" --name "$dst" --value "$val" --type SecureString --overwrite
}
copy_param /chainalert/production/POSTGRES_USER          /shared/production/POSTGRES_USER
copy_param /chainalert/production/POSTGRES_PASSWORD      /shared/production/POSTGRES_PASSWORD
copy_param /chainalert/production/POSTGRES_DB            /shared/production/POSTGRES_DB
copy_param /chainalert/production/CLOUDFLARE_ORIGIN_CERT /shared/production/CLOUDFLARE_ORIGIN_CERT
copy_param /chainalert/production/CLOUDFLARE_ORIGIN_KEY  /shared/production/CLOUDFLARE_ORIGIN_KEY
# /shared/production/REDIS_PASSWORD already exists — verify:
aws ssm get-parameter --region "$REGION" --name /shared/production/REDIS_PASSWORD --with-decryption > /dev/null
```

### 2. Confirm both DBs live on the same postgres instance

On the VPS:
```bash
cd /opt/chainalert
docker compose -f docker-compose.prod.yml exec postgres \
  psql -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2-)" -l
```
Expect to see both `chainalert` and `sentinel` in the list. If `sentinel`
is missing, stop — sentinel's DB is somewhere unexpected and needs
separate handling.

### 3. Take a dump of the sentinel DB (safety net)

```bash
cd /opt/chainalert
docker compose -f docker-compose.prod.yml exec -T postgres pg_dump \
  -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2-)" \
  -d sentinel --no-owner --no-acl \
  | gzip > ~/sentinel-precutover-$(date +%Y%m%d_%H%M).sql.gz
ls -lh ~/sentinel-precutover-*.sql.gz
```

Also dump chainalert just in case:
```bash
bash /opt/chainalert/scripts/backup-db.sh
ls -lh /opt/chainalert/backups/
```

## Cutover (maintenance window)

All steps on the VPS unless noted.

### 1. Stop chainalert (postgres + redis go down — sentinel will error)

```bash
cd /opt/chainalert
docker compose -f docker-compose.prod.yml down
```

### 2. Stop the old gateway nginx

```bash
cd /opt/gateway
docker compose down
```

### 3. Copy volumes: `chainalert_*` → `shared_*`

```bash
docker volume create shared_pgdata
docker volume create shared_redisdata

docker run --rm \
  -v chainalert_pgdata:/from \
  -v shared_pgdata:/to \
  alpine sh -c "cp -a /from/. /to/"

docker run --rm \
  -v chainalert_redisdata:/from \
  -v shared_redisdata:/to \
  alpine sh -c "cp -a /from/. /to/"
```

Quick size sanity check — the two volumes should be very close in size:
```bash
docker run --rm -v chainalert_pgdata:/v alpine du -sh /v
docker run --rm -v shared_pgdata:/v    alpine du -sh /v
```

### 4. Deploy the new `shared` stack

From your workstation:

```bash
# Push gateway repo main (this repo) — CI will:
#  - write TLS certs to /opt/shared/certs/
#  - write .env to /opt/shared/.env
#  - clone the repo to /opt/shared/repo/
#  - run scripts/deploy.sh which brings up nginx + postgres + redis
git push origin main
```

Watch the Actions run. `scripts/deploy.sh` health-checks all three
services before it exits.

### 5. Verify the DBs are intact

```bash
docker compose -f /opt/shared/docker-compose.yml exec postgres \
  psql -U "$(grep '^POSTGRES_USER=' /opt/shared/.env | cut -d= -f2- | tr -d \"\'\")" -l
# Expect: chainalert, sentinel, postgres, template0, template1
```

### 6. Kick sentinel to reconnect

The `postgres` and `redis` network aliases are unchanged, so sentinel's
`.env` needs no edits. Just restart:

```bash
cd /opt/sentinel
docker compose -f docker-compose.prod.yml restart api worker web
docker compose -f docker-compose.prod.yml ps
```

Smoke test:
```bash
curl -fsS https://sentinel.chainalert.dev/health
curl -fsS https://sentinel.chainalert.dev/
```

## Post-cutover cleanup (do once confident, hours/days later)

### Drop the chainalert database

```bash
docker compose -f /opt/shared/docker-compose.yml exec postgres \
  psql -U "$POSTGRES_USER" -c "DROP DATABASE chainalert;"
```

### Remove the old chainalert project on the VPS

```bash
cd /opt/chainalert
# (compose is already stopped from step 1)
sudo rm -rf /opt/chainalert /opt/gateway
```

### Remove orphan volumes

```bash
docker volume rm chainalert_pgdata chainalert_redisdata chainalert_logs
# Confirm nothing else is using them first:
# docker ps -a --filter volume=chainalert_pgdata
```

### Remove chainalert redis keys (if the DB-copy carried them over)

```bash
docker compose -f /opt/shared/docker-compose.yml exec redis \
  redis-cli -a "$REDIS_PASSWORD" --scan --pattern 'chainalert:*' | \
  xargs -r docker compose -f /opt/shared/docker-compose.yml exec -T redis \
    redis-cli -a "$REDIS_PASSWORD" DEL
# Or, if nothing else is in redis DB 0 besides sentinel's BullMQ queues
# and you're comfortable: FLUSHDB on a chainalert-only index.
```

### Repo archival

- Chainalert repo on GitHub: archive or disable `.github/workflows/deploy.yml`.
- Remove the stale chainalert DNS records (`chainalert.dev`, `www.chainalert.dev`) from Cloudflare if they're no longer needed.
- Delete `/chainalert/production/*` SSM parameters.

## Rollback

If the new stack fails health checks on the VPS:

```bash
# Bring sentinel down to avoid error spam
cd /opt/sentinel && docker compose -f docker-compose.prod.yml stop

# Bring shared stack down
cd /opt/shared && docker compose down

# Relaunch the old chainalert stack (postgres/redis come back with their
# original volumes)
cd /opt/chainalert && docker compose -f docker-compose.prod.yml up -d

# Relaunch the old gateway nginx
cd /opt/gateway && docker compose up -d

# Restart sentinel
cd /opt/sentinel && docker compose -f docker-compose.prod.yml up -d
```

The `chainalert_*` volumes are untouched by the copy (we only read them),
so rollback is clean.
