# Shared Infra

Single Docker Compose stack that provides the **nginx gateway**, **shared
postgres**, and **shared redis** for every app deployed on the Hetzner VPS.
Apps bring only their own code — they reach the shared services over two
external Docker networks.

(The repo is still called `gateway` on GitHub; the project name inside
compose is `shared`, and everything lives under `/opt/shared/` on the host.)

## Architecture

```
Internet → Cloudflare → VPS:443 → nginx (gateway network)
                                    └─ sentinel.chainalert.dev → sentinel-api / sentinel-web

                                  postgres (shared-infra network, alias "postgres")
                                  redis    (shared-infra network, alias "redis")
                                    ↑
                                    └─ sentinel-api / sentinel-worker / ...
```

Two external Docker networks, created idempotently by `scripts/deploy.sh`:

- **`gateway`** — any app container that needs HTTPS routing via nginx.
- **`shared-infra`** — any app container that needs postgres or redis.

Nginx uses Docker's embedded DNS resolver (`127.0.0.11`) with variables in
each `conf.d/*.conf` so it starts even when downstream apps are offline.

## Files

```
docker-compose.yml          # nginx + postgres + redis, project name "shared"
.env.example                # POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB / REDIS_PASSWORD
nginx/
  nginx.conf                # main config, HTTP→HTTPS redirect, health check
  conf.d/
    sentinel.conf           # sentinel.chainalert.dev routing
certs/                      # .gitignored — written by CI from SSM
  origin.pem
  origin-key.pem
scripts/
  deploy.sh                 # host deploy script (runs on VPS via SSH)
  backup-db.sh              # pg_dump a named DB to /opt/shared/backups
```

## Deployment

Auto-deploys on push to `main` via GitHub Actions → SSH → `scripts/deploy.sh`.

Manual deploy:
```bash
ssh deploy@vps "cd /opt/shared/repo && bash scripts/deploy.sh"
```

### Secrets (SSM, AWS region per workflow)

The deploy workflow reads from `/shared/production/*` and writes the
rendered `.env` to `/opt/shared/.env` on the host.

| SSM parameter | Purpose |
|---|---|
| `/shared/production/POSTGRES_USER` | postgres superuser |
| `/shared/production/POSTGRES_PASSWORD` | postgres superuser password |
| `/shared/production/POSTGRES_DB` | default DB created on first init (existing volume already has multiple DBs) |
| `/shared/production/REDIS_PASSWORD` | redis `--requirepass` |
| `/shared/production/CLOUDFLARE_ORIGIN_CERT` | TLS cert PEM |
| `/shared/production/CLOUDFLARE_ORIGIN_KEY` | TLS cert key PEM |

GitHub Actions secrets: `APP_ID`, `APP_PRIVATE_KEY`, `AWS_ACCOUNT_ID`,
`AWS_REGION`, `AWS_ROLE_NAME`, `HETZNER_HOST`, `HETZNER_USER`,
`HETZNER_SSH_KEY`.

## Onboarding a new app

1. **App needs postgres/redis**: in its `docker-compose.prod.yml`, join the
   `shared-infra` network (`external: true`). Reach postgres at
   `postgres:5432` and redis at `redis:6379`. Create the app's database
   once via:
   ```bash
   docker compose -f /opt/shared/docker-compose.yml exec postgres \
     psql -U "$POSTGRES_USER" -c "CREATE DATABASE myapp;"
   ```
2. **App needs HTTPS routing**: join the `gateway` network with a stable
   alias (e.g. `myapp-api`, `myapp-web`), then add a
   `nginx/conf.d/myapp.conf` following the `resolver + set $var` pattern
   from `sentinel.conf`. Push to `main`.
3. **App needs SSM secrets**: store them at `/myapp/production/*` and have
   the app's own deploy workflow fetch them. Do **not** add them to
   `/shared/production/*` — that path is reserved for cross-app values.

## Adding a new gateway route only

Just drop `nginx/conf.d/<service>.conf` that proxies to the app container
hostname. Push — the deploy script `cp`s the dir and reloads nginx.

## Backups

`scripts/backup-db.sh <db-name>` dumps a named database. Install the
suggested crontab line on the VPS for each DB you want backed up.
