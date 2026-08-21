# NetBird management stack upgrade runbook

Applies to the Terraform-managed production stack in `infra/terraform`.
Written for the staged 0.76.1 → 0.77.0 upgrade (2026-08-14); reusable for any
management upgrade by repeating the PREPARE phase with new versions.

## Design recap

All image versions are pinned by OCI **index digest** in `infra/terraform/locals.tf`.
Changing a pin updates the management SSM document; applying re-runs the
bootstrap association on the instance, which rewrites the compose file and lets
`docker compose up -d` recreate exactly the containers whose image changed.
Never `docker pull` by hand on the host — the next bootstrap run reverts drift.

## PREPARE (done 2026-08-14 for 0.77.0 — safe, nothing applied)

1. **Pick versions as a pair.** Management/signal/relay share one tag; the
   dashboard has its own tag released alongside it (here `0.77.0` + `v2.91.0`,
   both 2026-08-13). oauth2-proxy/caddy/coturn upgrade on their own cadence.
2. **Read release notes** for every version between current and target
   (`0.76.2`, `0.76.3`, `0.77.0`): look for management.json schema changes,
   dashboard env var changes, embedded-IdP changes, manual migration steps.
   Result for 0.77.0: none flagged.
3. **Fetch digests from the registry** (matches the pin form used in locals.tf):
   `docker buildx imagetools inspect netbirdio/management:0.77.0` → `Digest:`.
   Confirm a `linux/arm64` manifest exists.
4. **Edit `locals.tf`** pins, `terraform fmt`, then dry run:
   `terraform plan` must show ONLY
   `aws_ssm_document.management_bootstrap` + `aws_ssm_association.management_bootstrap[0]`
   updated **in-place** — 0 add, 0 destroy, no `aws_instance` changes, no peer
   resources. Decode the `compose_b64` blob in the plan JSON and confirm the
   intended image pins (see `migration` scripts history for the one-liner).
5. Optionally let a day-zero release soak a few days; recheck the GitHub issue
   tracker before APPLY. If a patch release lands, redo steps 3–4 (minutes).

## APPLY (maintenance moment, ~1 minute of management restart)

1. `aws sso login --profile DevOpsAdministrator`
2. **Fresh snapshot immediately before** (schema migrations are one-way):
   `aws ec2 create-snapshot --volume-id vol-081592ad6b66c8d65 --description "pre-upgrade ..."`
   Wait for `completed`.
3. Re-run `terraform plan` (do not reuse a stale tfplan) and re-verify step 4
   invariants above.
4. `terraform apply`. The association reruns the bootstrap; only containers
   with changed images restart.
5. Verify:
   - `docker compose ps` on the host: 7/7 Up, correct new image tags
   - `https://nbvpn.sleek.com/healthz` → 401; `/` → 302 to JumpCloud
   - `netbird status` on a client: Management/Signal connected
   - dashboard login + peers list renders
6. Commit/push the pin change if not already committed.

## ROLLBACK

Images alone: revert the pins in git → plan → apply (containers go back).
If the schema migrated and the datastore no longer works on the old version:
stop the stack, restore `/srv/netbird` from the step-2 snapshot (create volume
from snapshot, swap attachment), revert pins, apply. Old binaries + new schema
is the one combination that must never run.

## Peers (separate, later)

Peer RPM version is pinned separately in `locals.tf` (`0.76.1`). Management may
run ahead of clients within reason (mgmt ≥ client). To upgrade enrolled peers:
bump the RPM pin + rerun the peer associations, or `dnf update netbird` via SSM
one peer at a time, watching `netbird status` and routed-traffic health.

## Current staged state (2026-08-14)

- `locals.tf` carries the 0.77.0/v2.91.0 pins — **committed but NOT applied**;
  production still runs 0.76.1/v2.90.9 until the APPLY phase runs.
- Dry-run verified: 2 in-place updates only; decoded compose contains exactly
  the 4 new pins; DLM dailies (14-day retention) active on the data volume.
