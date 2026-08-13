# NetBird migration — executive review

**Goal.** Replace the hand-built x86 NetBird deployment (Docker Compose management
+ two directly-installed exit nodes) with the Terraform-managed ARM64 stack in
`infra/terraform`, with zero data loss and one short, planned downtime window.

**Requested approval.** Every action below. After approval, execution waits only
for an admin AWS SSO profile. All facts were gathered read-only on 2026-08-13
with `DevOpsAdministrator-readonly` (account 560723684645, ap-southeast-1);
nothing has been changed yet.

---

## 1. Current state (verified read-only, 2026-08-13)

| Role | Instance | Type/arch | OS | Access today | Root volume |
|---|---|---|---|---|---|
| NetBird management (Compose project `netbird-new`, 7 services, images `:latest`) | `i-0ebece0782d6bd148` | t3.small x86 | Ubuntu 24.04 | SSH key `management-stage-sg`; **no IAM profile / no SSM** | `vol-096c5b0c627728431` 30 GiB gp3 **unencrypted, zero snapshots** |
| Exit node 1 (`nb-prod-exitnode-01`, netbird client on host) | `i-071741f3f69aabd73` | t3.small x86 | AL2023 | SSH key `management-prod-sg`; no SSM | 15 GiB unencrypted |
| Exit node 2 (`nb-prod-exitnode-02`) | `i-006ffee7739f25a05` | t3.small x86 | AL2023 | SSH key `management-prod-sg`; no SSM | 15 GiB unencrypted |
| Standalone exit node (`nb-prod-exitnode-only-01`, Terraform `infra/terraform/exit-node`) | `i-04ee9689986275774` | t4g.micro arm64 | AL2023 | SSM | 16 GiB encrypted |

- DNS: `nbvpn.sleek.com` → 18.136.135.128 (Cloudflare-managed, DNS-only). **No DNS change needed at any point** — cutover is EIP re-association only.
- The existing DLM backup policy covers only the two OpenVPN instances. The NetBird datastore has **no backup today**.
- Live config files were fetched over SSH (`iznogoud@10.241.0.14`, `~/netbird-new`) on 2026-08-13 into gitignored `migration/.fetched/live/`. The four secret-bearing files (`management.json`, `relay.env`, `turnserver.conf`, `dashboard.env`) are **byte-identical** to the local copies in `deploy/management/` — datastore key, relay secret, and TURN password sources are confirmed current. There is **no `.env` on the server**: the live compose hardcodes the JumpCloud OAuth credentials inline, so Phase A extracts them from the fetched compose file (no JumpCloud console access needed).
- **Config drift found and fixed:** live allows OAuth group `"NetBird Administrator"`, while the Terraform example said `"NetBird Staging Admin"` — the stale value would have locked admins out of the new dashboard. The migration tfvars now carry the live value. Live `oauth2-proxy:latest` resolves to the same v7.15.3 digest Terraform pins.
- **Live image digests match the Terraform pins exactly** (management/signal/relay 0.76.1, dashboard v2.90.9, oauth2-proxy v7.15.3, caddy 2.11.4) — the one-way schema-migration risk is cleared. Only coturn differs (stateless, harmless).
- The live Caddyfile embeds the current health token in plaintext (and the file is group/world-readable on the server); treat that token as burned — the migration rotates it by design.
- Termination protection is off on all three old instances.

### Data that must survive (and where it lives)

1. **Management datastore** — SQLite in docker volume `netbird-new_netbird_management` (container path `/var/lib/netbird`): all peers (incl. every end-user device), setup keys, groups, policies, routes, users. *Migrated byte-for-byte.*
2. **Datastore encryption key** — `DataStoreEncryptionKey` in live `management.json`. *Carried into the new management secret; without it the copied DB is unreadable.*
3. **Relay secret, TURN password, JumpCloud OAuth client id/secret** — carried over unchanged. Cookie secret and health token are **deliberately rotated** (impact: dashboard re-login; update external monitor if any).
4. **Caddy ACME certificates** (`caddy_data/`) — copied so the new host serves valid TLS before any cutover.
5. **End-user clients** — no action: they point at the unchanged domain; their records ride along in the datastore.
6. Old exit-node WireGuard identities are intentionally **not** migrated — new peers enroll with fresh one-off setup keys; old peer records are deleted from the dashboard after acceptance.

## 2. EIP record — before and after

| EIP | Allocation ID | Before (today) | After migration |
|---|---|---|---|
| 18.136.135.128 (mgmt, = `nbvpn.sleek.com`) | `eipalloc-0cdfcdf07221f2f96` | `i-0ebece0782d6bd148` NetBird MGMT Server | new `sleek-netbird-production-management` (Phase B, gate 2) |
| 18.143.19.220 (exit 1 egress) | `eipalloc-03cb123d9dd951339` | `i-071741f3f69aabd73` nb-prod-exitnode-01 | new `sleek-netbird-production-peer-1` (Phase C) |
| 47.130.71.73 (exit 2 egress) | `eipalloc-02f15b26c1f2b84ea` | `i-006ffee7739f25a05` nb-prod-exitnode-02 | new `sleek-netbird-production-peer-2` (Phase C) |
| 54.251.252.75 / 18.139.67.188 (OpenVPN) | `eipalloc-0b6b4659afdf970d1` / `eipalloc-07280dc93449b057f` | OpenVPN staging / production | **untouched** |
| 13.215.99.119 (unattached spare) | `eipalloc-08d845f3ddc25ddd5` | — | **untouched** |

Because egress IPs move with the EIPs, every external allowlist (databases,
SaaS) keeps working with no third-party change. New instance IDs are emitted by
`terraform output instances` at Phase A and recorded in this file's follow-up.

## 3. Planned actions

All scripts live in `migration/scripts/` and are idempotent; every Terraform
step does a machine-checked plan readback (exact resource counts, nothing
destroyed) before an explicit typed confirmation.

### Phase A — daytime, zero production impact (`00`–`04`, ~2–3 h elapsed)

| # | Action | Writes |
|---|---|---|
| A1 | `00-preflight.sh` — snapshot old mgmt root volume (its first backup ever) | EC2 snapshot |
| A2 | Create scratch bucket `sleek-netbird-migration-scratch-560723684645` (SSE-KMS, public-blocked, 7-day auto-expiry) | S3 |
| A3 | Create role/profile `sleek-netbird-migration-ssm` (AmazonSSMManagedInstanceCore only) and attach to the three old instances → gives SSM access without touching SSH | IAM, EC2 |
| A4 | Fetch live config files off the old mgmt host into gitignored `migration/.fetched/`; **assert live NetBird version == pinned 0.76.1** (abort on mismatch — schema migrations are one-way); optional full API export with a PAT | none |
| A5 | `01-apply-parallel-stack.sh` — `terraform apply`: 3 × t4g.small ARM64 + encrypted volumes + SGs + IAM + empty secrets + alarms. Readback: exactly 3 instances, 0 SSM associations, 0 EIP associations, 0 destroys | EC2/IAM/SM/CW |
| A6 | `02-populate-secrets.sh` — assemble management secret from live files (same datastore key, relay secret, TURN password, OAuth creds; new cookie secret + health token), schema-validate, `put-secret-value`; store 2 one-off peer setup keys | Secrets Manager |
| A7 | `04-bootstrap-management.sh` — SSM bootstrap of the new mgmt stack (7 pinned-digest services) on an empty datastore; verify 401/`healthz` + 308 redirect via `--resolve` against its temporary IP. DNS/EIP untouched | SSM |
| A8 | `03-copy-data.sh rehearsal` — full dress rehearsal of the copy/restore path: hot copy via presigned S3 URLs (old host uploads with bare curl, new host downloads with bare curl; SHA-256 verified end-to-end; previous generation kept in `/srv/netbird/previous`) | S3 (auto-expiring) |

After A8 the new management runs a real (rehearsal) copy of production data and
answers correctly on its temporary IP. Production has not noticed anything.

### Phase B — downtime window, outside business hours (`05`, target 15–30 min)

| Step | Action | Gate |
|---|---|---|
| B1 | Pre-checks: snapshot completed, EIP still on old mgmt, new stack healthy | auto |
| B2 | **`docker compose down` on the old stack** — downtime starts; the old writer never starts again (two live writers = divergent state, the one real data-loss risk) | **human: `STOP_OLD_STACK`** |
| B3 | Final **cold** copy (SQLite quiesced) → SHA-256 → restore on new host → all services up → 401/308 verification on temporary IP | auto, aborts on any mismatch |
| B4 | Terraform EIP cutover of `18.136.135.128` (readback: exactly one `aws_eip_association`, rollback holder recorded, confirmation phrase set) | **human: `MOVE_MGMT_EIP`** |
| B5 | Post-verify through real DNS (308 / 401 / fixed redirect), then clear the confirmation phrase. Clients and both old exit nodes reconnect to the new control plane automatically; routing continues on the old exit nodes | auto |

Rollback before B4: restart the old stack — EIP never moved, users see nothing.
Rollback after B4: `90-rollback.sh management` (stops new writer → returns EIP →
restarts old stack → removes the association from Terraform state).

### Phase C — next day(s), one peer at a time (`06`)

Per peer: enable bootstrap gate → apply (RPM pinned by SHA-256+signature, enroll
via setup key) → verify `netbird status` checks → **human dashboard check**
(new peer in the routing group ⇒ group routes gain an HA member) → EIP move with
the same readback/confirmation machinery → verify egress IP == the EIP →
delete the old peer from the dashboard, revoke its key. peer_1 fully accepted
before peer_2 starts.

### Decommission — after a 1–2 week rollback-hold

Stop (not terminate) the three old instances; snapshot before eventual
termination; detach the migration SSM profile; delete rehearsal artifacts. Will
be proposed as a separate reviewed step.

## 4. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Live `:latest` management is newer than pinned 0.76.1 → one-way schema mismatch | **Cleared 2026-08-13:** live digests verified over SSH and equal the pins exactly; A4 still re-asserts this on migration day |
| Two control-plane writers diverge | Old stack is stopped at B2 and never restarted; rollback script stops the new writer before returning the EIP |
| Copy corruption | Cold copy in the window; SHA-256 manifest verified on both ends; rehearsal proves the exact path in Phase A; previous generation retained on the new volume |
| Losing admin access to the old host mid-window | SSM attached in Phase A **and** SSH fallback (`OLD_MGMT_SSH`) supported by every old-host step |
| EIP moved to a broken stack | EIP move is the *last* step, after data restore + HTTP verification; typed gate; `90-rollback.sh` returns it in ~1 min |
| Old datastore has no backup at all today | First action of Phase A is a snapshot, before anything else |
| Secret material leaking | Secrets only flow live-host → gitignored `.fetched/` → Secrets Manager; never into Terraform state, git, or logs; scratch bucket is SSE-KMS, public-blocked, 7-day expiry |
| Terraform stealing the EIP back after a manual rollback | Rollback script does `terraform state rm` + gate off + zero-change plan readback |

Residual risks accepted: ~15–30 min VPN control-plane outage in the window
(existing P2P WireGuard sessions mostly survive; relay/TURN sessions drop);
dashboard sessions invalidated (rotated cookie secret); the health token
changes (update external monitors, if any).

## 5. Decisions needed from you (defaults applied if you just approve)

1. **State backend** — default: `sleek-tfstate-devops-mgmt-560723684645-ap-southeast-1-an`, key `sleek-netbird/production/terraform.tfstate` (versioned, this account's infra states live there).
2. **`nb-prod-exitnode-only-01`** — default: **keep, untouched**. It is an independent single-purpose stack pointing at the same domain; its peer record rides along in the copied datastore. Follow-up (not part of this migration): move its local tfstate into the same S3 backend.
3. **Routes by group or by peer?** — checked automatically in A4 when a `NETBIRD_PAT` is provided (recommended), else a manual dashboard check before Phase C. If any route targets a specific peer rather than a group, the new peer is added to that route before the old one is removed.
4. **Uncommitted repo changes** — the `peer-bootstrap.sh.tftpl` fix (ManagementURL as object, learned from the standalone exit node) plus README/.gitignore edits get committed before Phase A. Default: yes.
5. **Maintenance window** — you pick date/time; scripts enforce nothing time-based.

## 6. What you approve by approving this document

- The IAM/S3/snapshot/SSM preparation writes in Phase A (A1–A4).
- Creation of the parallel Terraform stack and secret population (A5–A8).
- One downtime window executed by `05-cutover-management.sh` with the two typed
  human gates above, moving only `eipalloc-0cdfcdf07221f2f96`.
- Per-peer Phase C cutovers moving `eipalloc-03cb123d9dd951339` and
  `eipalloc-02f15b26c1f2b84ea`, each behind its own typed gate.
- The old stack is stopped permanently at B2; instances are retained stopped for
  rollback and decommissioned only via a later, separate approval.

**Not** included (needs nothing from you now): DNS changes (none), OpenVPN
instances (untouched), the spare EIP (untouched), old-instance termination
(separate approval later).
