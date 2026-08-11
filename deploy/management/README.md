# Local Deployment Secrets

The checked-in files are templates. Runtime credentials must stay on the host
and must never be committed.

Enter this directory and create the local files before starting Compose:

```sh
cd deploy/management
cp .env.example .env
cp dashboard.env.example dashboard.env
cp management.json.example management.json
cp relay.env.example relay.env
cp turnserver.conf.example turnserver.conf
```

Fill `.env` with the OAuth2-Proxy values, and replace the placeholders in the
dashboard, management, relay, and TURN files with values from the secret store.
Restrict the files to the deployment administrator (`chmod 600 .env
dashboard.env management.json relay.env turnserver.conf`).

This directory is the only canonical Compose deployment. Its local
`.gitignore`, reinforced by the repository root rules, excludes runtime files,
Caddy ACME state, private keys, backups, captures, and generated artifacts.

## NetBird health endpoint

Generate a token and add it to the host-only `.env` file:

```sh
openssl rand -hex 32
```

```dotenv
NETBIRD_HEALTH_TOKEN=<generated-token>
```

Caddy exposes `GET /healthz` and proxies an authenticated request to the
Management service's internal Prometheus endpoint at `management:9090/metrics`.
The metrics port remains private to the Compose network. Validate and reload
Caddy after changing the configuration. Recreate the container the first time
so it receives `NETBIRD_HEALTH_TOKEN` from Compose:

```sh
docker compose up -d --force-recreate caddy
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Verify that unauthenticated access is denied and the token-authenticated check
succeeds:

```sh
curl -i https://nbvpn.sleek.com/healthz
curl -fsS \
  -H "Authorization: Bearer $NETBIRD_HEALTH_TOKEN" \
  https://nbvpn.sleek.com/healthz >/dev/null && echo healthy
```

The first request must return `401`; the second must print `healthy`. A success
confirms that Caddy can reach the NetBird Management metrics server. Keep the
token only in `.env` or the deployment secret store; never commit its value.
