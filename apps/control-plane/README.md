# Sleek Network Control

Internal web application for discovering AWS and MongoDB Atlas infrastructure through Steampipe, viewing the current NetBird configuration, creating networks, and adding EC2/RDS/MongoDB DNS resources to NetBird in bulk.

## What It Does

- Queries `aws_staging` and `aws_production` separately, preserving the account boundary on every EC2 and RDS row.
- Includes every configured AWS region and reads EC2 private DNS plus RDS endpoint DNS.
- Reduces every MongoDB Atlas connection URL, including nested private endpoint strings, to one lowercase DNS hostname with credentials, protocols, ports, paths, and duplicate cluster domains removed.
- Classifies MongoDB clusters containing `production` as production and clusters containing `dev`, `development`, `nonprod`, or `staging` as staging. Other names remain explicitly unclassified.
- Shows NetBird networks, resources, routers, peers, groups, and policies.
- Creates empty NetBird networks from a validated operator form.
- Creates empty NetBird resource groups from a validated operator form.
- Creates and updates NetBird policies with one or more rules targeting groups or existing NetBird resources, and edits existing network routers.
- Supports `accept` and `drop` actions, TCP/UDP port lists and ranges, ICMP, NetBird SSH, bidirectional rules, and explicit enablement controls.
- Selects up to 1,000 AWS and MongoDB resources with environment filters, automatically checks duplicates, confirms the change, and reports every NetBird API result.

The NetBird contract is implemented from
[`../../contracts/netbird/openapi.yml`](../../contracts/netbird/openapi.yml).
NetBird has a single-resource create endpoint, so this application performs
controlled concurrent requests rather than claiming a native bulk API exists.

## Prerequisites

- Node.js 20.9 or newer
- Steampipe v2 with the AWS and MongoDB Atlas plugins
- Configured Steampipe connections named `aws_staging`, `aws_production`, and `mongodbatlas` (names can be overridden)
- A NetBird personal access token for live reads and writes

The existing AWS connections already use `regions = ["*"]`, which is what makes the inventory cover every AWS region.

## Local Start

```bash
steampipe service start --database-listen local
cd apps/control-plane
cp .env.example .env.local
npm ci
npm run dev
```

Open `http://localhost:3000`. If that port is occupied, Next.js will select another port.

Without `NETBIRD_API_TOKEN`, only NetBird uses clearly labeled demo data. Steampipe inventory remains live. A demo bulk commit is simulated and never sends a write.

## Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `STEAMPIPE_DATABASE_URL` | `postgres://steampipe@127.0.0.1:9193/steampipe` | Server-only Steampipe PostgreSQL endpoint |
| `STEAMPIPE_STAGING_SCHEMA` | `aws_staging` | Staging AWS connection/schema |
| `STEAMPIPE_PRODUCTION_SCHEMA` | `aws_production` | Production AWS connection/schema |
| `STEAMPIPE_MONGODB_SCHEMA` | `mongodbatlas` | MongoDB Atlas connection/schema |
| `NETBIRD_API_URL` | `https://nbvpn.sleek.com` | Self-hosted NetBird management origin |
| `NETBIRD_API_TOKEN` | empty | Server-only NetBird PAT; the `Token` prefix is optional |
| `NETBIRD_REQUEST_TIMEOUT_MS` | `15000` | Timeout per NetBird HTTP request |
| `NETBIRD_DEMO_MODE` | `false` | Force NetBird demo mode even when a token exists |

Do not prefix server secrets with `NEXT_PUBLIC_`. The browser only calls the application routes and never receives either backend credential.

## Naming Rules

- EC2 with a Name tag: `instance-id (Name)`
- EC2 without a Name tag: `instance-id`
- RDS: `db-instance-identifier`
- Duplicate RDS identifiers: `db-instance-identifier (environment-region)`
- MongoDB with one domain: `cluster-name`
- MongoDB with multiple domains: `cluster-name (normalized-domain)`

The instance ID remains in EC2 names because autoscaled instances often share the same Name tag, while NetBird requires resource names to be unique across the account.

## Bulk Safety

1. The operator filters and selects EC2, RDS, and/or normalized MongoDB domains.
2. The operator chooses one NetBird network and at least one resource group.
3. The bulk target shows current resource counts for the selected network and resource groups.
4. The server automatically compares selected names and DNS addresses against resources in all NetBird networks, and repeats that check immediately before a write.
5. Existing and within-batch duplicates are skipped with explicit locations and reasons.
6. The operator confirms only the ready rows.
7. Requests run with concurrency four and return created, skipped, or failed status for each row.

Network creation, resource-group creation, and resource creation are separate explicit actions. Opening a form or running a bulk preview never sends a NetBird mutation.

## Policy Safety

1. New policies and rules start disabled until an operator enables them.
2. Each rule requires exactly one source and destination mode: groups or a single existing NetBird resource.
3. Ports accept comma-separated values and ranges, for example `80,443,1000-2000`, and are limited to TCP or UDP.
4. Policy edits use NetBird's replacement endpoint while preserving existing rule IDs, posture checks, and authorization mappings.

Deploy this application behind the repository's existing OAuth2-Proxy/Caddy administrative boundary. The app intentionally does not invent a second identity system.

## Verification

```bash
npm test
npm run lint
npm run typecheck
npm run build
npm audit --omit=dev
```
