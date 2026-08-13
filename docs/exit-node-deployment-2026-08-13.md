# Exit-node deployment session notes — 2026-08-13

Deployment record for the standalone `t4g.micro` NetBird exit node, plus the
security-group cleanup applied to the existing hand-managed peers. All work in
the devops account (560723684645), ap-southeast-1.

## Deployed and live

- **New module** `infra/terraform/exit-node/` (local state inside that
  directory): one `t4g.micro` AL2023 ARM64 exit node, IMDSv2-only, encrypted
  gp3, SSM-managed, setup key via Secrets Manager (never in Terraform state).
- **Instance** `i-04ee9689986275774`, hostname `nb-prod-exitnode-only-01`,
  NetBird IP `100.64.59.131`, enrolled against `nbvpn.sleek.com`, WireGuard
  port 51820 bound and verified. Public IPv4 is auto-assigned (no EIP yet, see
  pending) — it changes on stop/start.
- **Secret** `nb/prod/exitnode-only-01/setup-key`
  (`...secret:nb/prod/exitnode-only-01/setup-key-Wsb4RK`). The key used on
  2026-08-13 was single-use and is consumed.
- **SG for the new node** `sg-001311327044bf435` (Terraform-owned): inbound
  UDP 51820 only, all egress.
- **SG `nb-prod-peers`** `sg-019bfc4796c162f66` (created by CLI, tagged
  `ManagedBy=manual-cli`): inbound UDP 51820 + TCP 22 from prefix lists
  `pl-000f9420a91cfc3b6`/`pl-073f7512b7b9a2450`, all egress. Attached to both
  hand-managed peers `nb-prod-exitnode-01` (`i-071741f3f69aabd73`, EIP
  18.143.19.220) and `nb-prod-exitnode-02` (`i-006ffee7739f25a05`, EIP
  47.130.71.73), replacing the copy-pasted coturn SG. EIPs unaffected.

## Bugs found and fixed in the bootstrap templates

Both fixes applied to `infra/terraform/exit-node/templates/exit-node-user-data.sh.tftpl`
**and** `infra/terraform/templates/peer-bootstrap.sh.tftpl` (the 3-node module
had the same latent bugs, never applied):

1. NetBird 0.76.1 persists `ManagementURL`/`AdminURL` as Go `url.URL` objects
   (`{"Scheme":"https","Host":"host:443"}`), not strings. A string value makes
   the daemon crash-loop on config unmarshal.
2. Omitting `WgPort` from `default.json` yields `WgPort: 0` = random listen
   port, which silently defeats any UDP 51820 ingress rule. Templates now pin
   `WgPort: 51820`.

The live instance was fixed with `netbird down && netbird up --wireguard-port
51820` (no new setup key needed — down/up does not deregister).

## Audit snapshot (2026-08-13, read-only)

- `netbird-prod-vpn-01/02` (the two t3.smalls): both on WgPort 51820 already;
  clients reach them **P2P direct** on 51820 through the new SG. CPU max ~11%,
  credit balance pegged at 576/576, network peaks 11–21 Mbps vs ~128 Mbps
  baseline, conntrack <1%, swap unused. Roughly 1–2% utilized.
- They are **split-tunnel routing peers** (SaaS domain routes: anthropic,
  openai/chatgpt, mongodb, rds, sleek domains, `10.241.0.0/24`), in an HA pair
  — vpn-02 active, vpn-01 standby. ~54 peers in the network.
- The new node carries **no routes yet** (see pending).
- vpn-01's NetBird IP is `100.64.211.11`; vpn-02 is `100.64.66.15`.

## Pending / decisions parked

1. **Dashboard step (blocking the node's purpose):** add the exit-node route
   for `nb-prod-exitnode-only-01` — `0.0.0.0/0`, masquerade ON, distribution
   groups. Terraform cannot do this; needs dashboard click or a NetBird PAT.
2. **EIP:** account quota 6/6 used; `create_eip = false` for now.
   `13.215.99.119` (`eipalloc-03cb...` no — `eipalloc-08d845f3ddc25ddd5`) is
   unassociated but ownership/purpose unconfirmed. Options: adopt it, raise the
   quota, or keep the ephemeral public IP.
3. **⚠️ Next `terraform apply` replaces the instance** (user-data changed by
   the template fixes; plan shows `1 add / 1 destroy`). Before applying: create
   a fresh single-use setup key and `put-secret-value` it, or the new instance
   cannot enroll. No apply is needed while the current instance is healthy.
4. **Old SG** `sg-005431f4a12b479f9` is now attached to nothing — kept as
   instant rollback for the peer SG swap. Delete after a few stable days.
5. **Mgmt SG** `sg-0b4ce7614d0abaa4b` still carries the useless typo rule
   `UDP 51280 "WireGuard"` (real WG port is 51820, and mgmt is not a peer).
   Safe to delete; removal not yet approved.
6. Repo changes (new module + template fixes + this note) are **uncommitted**.
7. `aws sso` profile `DevOpsAdministrator` now maps to `AdministratorAccess`
   on 560723684645; `DevOpsAdministrator-readonly` kept as ViewOnly.
