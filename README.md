# Sleek NetBird

Operational repository for Sleek's self-hosted NetBird deployment, endpoint
client tooling, and infrastructure-to-NetBird control plane.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`deploy/management/`](deploy/management/) | Canonical Compose deployment for `nbvpn.sleek.com` |
| [`infra/terraform/`](infra/terraform/) | Staged AWS IaC for one ARM64 management node and two ARM64 routing peers |
| [`apps/control-plane/`](apps/control-plane/) | Steampipe-backed AWS/MongoDB inventory and NetBird administration UI |
| [`client/`](client/) | macOS and Windows install, management-URL migration, uninstall, and tests |
| [`contracts/netbird/openapi.yml`](contracts/netbird/openapi.yml) | NetBird management API contract used by the control plane |
| [`plans/`](plans/) | Approved implementation and outstanding rollout plans |

## Self-hosted deployment

[`deploy/management/`](deploy/management/) contains the Compose file, Caddy
configuration, safe templates, and operating guide for the running
seven-service stack:

- Caddy
- NetBird Dashboard
- NetBird Signal
- NetBird Relay
- NetBird Management with embedded identity provider
- OAuth2-Proxy with JumpCloud OIDC
- Coturn

Runtime credentials and state are intentionally excluded from Git. Prepare
them using [`deploy/management/README.md`](deploy/management/README.md) before
running Compose.

```sh
cd deploy/management
docker compose config --quiet
docker compose up -d
```

The Compose file uses moving `latest` tags for several NetBird components
because it mirrors the current deployment. Pin image digests before treating a
new host build as reproducible.

The replacement EC2 deployment is codified separately under
[`infra/terraform/`](infra/terraform/). It fixes all three nodes to
`t4g.small`, pins the management images by multi-platform digest, keeps runtime
secret values outside Terraform state, and gates bootstrap and EIP cutover per
node. It does not modify or import the currently running instances.

## Control plane

The control-plane app discovers EC2, RDS, and MongoDB Atlas records through
Steampipe and reads or changes NetBird Networks, resources, routers, groups,
and policies through the management API.

```sh
cd apps/control-plane
cp .env.example .env.local
npm ci
npm run dev
```

See [`apps/control-plane/README.md`](apps/control-plane/README.md) for its
configuration, mutation safeguards, and verification commands. Keep
`.env.local` and its API token local.

## Client tooling

See [`client/README.md`](client/README.md). The scripts target
`https://nbvpn.sleek.com` and deliberately separate installation, endpoint
migration, and uninstall operations.

## Active operational plan

The database-access migration and routing-peer reliability work is specified
in [`plans/database-access-segmentation-and-routing-peer-reliability.md`](plans/database-access-segmentation-and-routing-peer-reliability.md).
It is a plan only: no live NetBird resources or policies are changed by this
repository reorganization.

## Repository checks

```sh
cd deploy/management
docker compose config --quiet
cd ../..

python3 client/tests/run_change_management_url_tests.py

cd infra/terraform
./scripts/validate.sh

cd apps/control-plane
npm test
npm run lint
npm run typecheck
npm run build
npm audit
```

Do not commit `.env`, `dashboard.env`, `management.json`, `relay.env`,
`turnserver.conf`, `.env.local`, API tokens, setup keys, private keys, HAR
files, certificate bundles, or Caddy state.
