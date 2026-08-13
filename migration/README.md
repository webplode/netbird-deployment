# NetBird x86 → ARM64 Terraform migration workspace

Read [`EXECUTIVE-REVIEW.md`](EXECUTIVE-REVIEW.md) first — it is the approval
document: current-state inventory, EIP before/after record, every planned
action, risks, and rollback.

## Layout

```
migration/
├── EXECUTIVE-REVIEW.md          approval document
├── tfvars/
│   ├── terraform.tfvars.migration-base   -> infra/terraform/terraform.tfvars
│   └── backend.hcl.migration             -> infra/terraform/backend.hcl
├── scripts/
│   ├── lib.sh                   constants (all verified IDs) + helpers
│   ├── set-tfvar.py             safe single-key tfvars editor
│   ├── presign.py               S3 presigned PUT/GET (run via uv --with boto3)
│   ├── 00-preflight.sh          snapshot, scratch bucket, SSM access, live fetch, version check
│   ├── 01-apply-parallel-stack.sh
│   ├── 02-populate-secrets.sh
│   ├── 03-copy-data.sh          rehearsal|final (presigned S3, SHA-256 verified)
│   ├── 04-bootstrap-management.sh
│   ├── 05-cutover-management.sh   ← the downtime window (2 typed human gates)
│   ├── 06-cutover-peer.sh peer_1|peer_2
│   └── 90-rollback.sh management|peer_1|peer_2
└── .fetched/                    gitignored: live configs, secrets, manifests
```

## Run order

```sh
export MIGRATION_AWS_PROFILE=<admin-sso-profile>       # never the readonly one
# Phase A (daytime, no production impact)
./scripts/00-preflight.sh
./scripts/01-apply-parallel-stack.sh
./scripts/02-populate-secrets.sh
./scripts/04-bootstrap-management.sh
./scripts/03-copy-data.sh rehearsal
# Phase B (maintenance window)
./scripts/05-cutover-management.sh
# Phase C (next day, one at a time)
./scripts/06-cutover-peer.sh peer_1
./scripts/06-cutover-peer.sh peer_2
```

Optional env: `NETBIRD_PAT` (Phase A API export + route audit),
`OLD_MGMT_SSH="ssh iznogoud@10.241.0.14"` (verified working 2026-08-13; used as
fallback if the old host never registers with SSM).

Every script is idempotent, verifies plan readbacks before applying, and stops
at typed confirmation phrases for the irreversible steps.
