# Gateway — Shared Nginx Reverse Proxy

Shared nginx gateway that routes traffic to multiple Docker Compose stacks on the same EC2 instance.

## Architecture

```
Internet → Cloudflare → EC2:443 → gateway nginx
                                    ├─ chainalert.dev      → chainalert stack
                                    └─ verity.chainalert.dev → verity-core stack
```

All stacks join an external Docker network called `gateway`. Nginx uses Docker's embedded DNS resolver (`127.0.0.11`) with variables so it starts even if downstream services aren't deployed yet.

## Files

```
docker-compose.yml          # nginx container, ports 80/443
nginx/
  nginx.conf                # main config, HTTP→HTTPS redirect, health check
  conf.d/
    chainalert.conf         # chainalert.dev routing
    verity.conf             # verity.chainalert.dev routing
certs/                      # .gitignored — written by deploy scripts
  origin.pem
  origin-key.pem
scripts/
  deploy.sh                 # EC2 deploy script (run via SSM)
```

## Deployment

Deploys automatically on push to `main` via GitHub Actions → SSM Send Command.

Manual deploy:
```bash
ssh ec2-host "cd /opt/gateway/repo && bash scripts/deploy.sh"
```

## Adding a new service

1. Add a `conf.d/<service>.conf` with `server_name` and `proxy_pass` using resolver pattern
2. In the service's `docker-compose.prod.yml`, join the `gateway` network with an alias
3. Push to main — gateway redeploys and picks up the new config

## Setup (new EC2 instance)

The gateway repo needs the same GitHub App and AWS OIDC role used by chainalert. Required GitHub Actions secrets:

- `APP_ID` / `APP_PRIVATE_KEY` — GitHub App for cloning private repos
- `AWS_ACCOUNT_ID` / `AWS_REGION` — AWS account info
- `EC2_INSTANCE_ID` — target EC2 instance

TLS certs are stored in SSM at `/chainalert/production/CLOUDFLARE_ORIGIN_CERT` and `CLOUDFLARE_ORIGIN_KEY`. The deploy script fetches them on first run if chainalert hasn't already written them to `/opt/gateway/certs/`.
