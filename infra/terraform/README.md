# Sleek NetBird AWS deployment

This Terraform root module creates a parallel ARM64 replacement for the current
NetBird topology:

- one management EC2 instance;
- two NetBird routing peers in separate Availability Zones;
- `t4g.small` for all three nodes;
- Amazon Linux 2023 ARM64;
- externally owned Elastic IPs, associated only through explicit cutover gates.

It does not import or modify the three running instances. A normal first apply
also does not move an EIP, start the management stack, or enroll a peer.

The evidence and architecture decision are recorded in
[`docs/terraform-ec2-arm64-research-brief.md`](../../docs/terraform-ec2-arm64-research-brief.md).

## What Terraform owns

- three EC2 instances and encrypted gp3 root volumes;
- one persistent, encrypted, prevent-destroy management data volume;
- management and routing-peer security groups;
- one IAM role/profile and one empty Secrets Manager secret per node;
- Systems Manager bootstrap documents and optional gated associations;
- CloudWatch instance-status, CPU, and CPU-credit alarms;
- optional associations to three pre-existing EIPs.

Terraform creates only the Secrets Manager metadata. It never receives or
stores a secret value, setup key, OAuth secret, health token, TURN password, or
NetBird datastore encryption key. Do not add an
`aws_secretsmanager_secret_version` resource to this module.

## Security defaults

- IMDSv2 is required. The container host uses hop limit 2; peers use 1.
- Session Manager is the normal administrative path.
- SSH has no ingress rule unless both an EC2 key and explicit administrator
  CIDRs are configured.
- Routing peers have no public application ingress. NetBird initiates its
  control, ICE, and relay connections outbound.
- EC2 source/destination checks are disabled on both routing peers.
- Management exposes only TCP 80/443 and UDP 443/3478.
- All EBS volumes are encrypted; the management data volume cannot be destroyed
  without first editing its static `prevent_destroy` lifecycle guard.
- Runtime images are pinned by version and multi-platform digest. Every selected
  image has a `linux/arm64` manifest.
- The peer RPM is pinned to the v0.76.1 ARM64 release SHA-256, checked against
  the pinned NetBird signing key, and installed without its auto-start
  scriptlet; the self-hosted profile is written before the daemon starts.
- Each instance role can read only its own runtime secret.
- EC2 API termination protection is enabled by default.

## Prerequisites

- Terraform 1.15.x;
- ripgrep for the local invariant checks;
- AWS credentials for the target account and `ap-southeast-1`;
- an existing S3 state bucket with versioning and the permissions needed for
  Terraform's S3 lock file;
- the existing VPC and the two target subnets;
- three existing EIP allocation IDs (`eipalloc-...`), not public IPv4 literals;
- two separate NetBird setup keys, preferably one-off, short-lived, and scoped
  to the intended routing-peer group;
- an approved maintenance and rollback window before copying management state
  or moving an EIP.

The example network IDs reflect read-only metadata observed on 2026-08-11.
Reconfirm them before use. Do not assign the live private addresses to the new
instances; leave `private_ipv4_addresses` omitted unless new unused addresses
have been reserved.

## 1. Initialize state and variables

```sh
cd infra/terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Fill the S3 backend, VPC/subnets, and all three EIP allocation IDs. Keep every
bootstrap and EIP cutover boolean `false`.

```sh
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive
terraform validate
terraform plan -out=first-apply.tfplan
terraform show first-apply.tfplan
```

The first plan must create exactly three `t4g.small` instances. It must contain
zero `aws_ssm_association` resources and zero `aws_eip_association` resources.
Apply only after that readback is true.

```sh
terraform apply first-apply.tfplan
```

Because `bootstrap_enabled` remains false, the new nodes stay side by side with
production. Their base user data sets the hostname, creates 2 GiB swap, and
starts SSM Agent; no NetBird credential is available to them.

## 2. Populate runtime secrets outside Terraform

Read the generated secret ARNs:

```sh
terraform output -json runtime_secret_arns | jq .
```

### Management secret

Copy the tracked schema to the ignored runtime filename and fill it from the
approved secret source:

```sh
cp management-secret.example.json management-secret.json
chmod 600 management-secret.json
```

`oauth2_cookie_secret_base64` must decode to exactly 16, 24, or 32 bytes. A
32-byte value can be generated with:

```sh
openssl rand -base64 32 | tr -- '+/' '-_' | tr -d '\n'
```

Write the value directly to Secrets Manager. The JSON file remains outside
Terraform and is ignored by Git:

```sh
management_secret_arn="$(terraform output -json runtime_secret_arns | jq -r .management)"
aws secretsmanager put-secret-value \
  --secret-id "$management_secret_arn" \
  --secret-string file://management-secret.json
unset management_secret_arn
```

Delete the local populated file through the workstation's recoverable secret
handling process after the Secrets Manager readback has been verified.

### Peer setup-key secrets

Each peer secret contains one raw NetBird setup key, not JSON. Do not reuse a
key intended for end-user devices. To avoid placing the value literally in shell
history, read it silently into a temporary mode-600 file:

```sh
peer_secret_file="$(mktemp)"
chmod 600 "$peer_secret_file"
read -r -s -p 'Peer setup key: ' peer_setup_key
printf '\n'
printf '%s' "$peer_setup_key" > "$peer_secret_file"
unset peer_setup_key

peer_1_secret_arn="$(terraform output -json runtime_secret_arns | jq -r .peer_1)"
aws secretsmanager put-secret-value \
  --secret-id "$peer_1_secret_arn" \
  --secret-string file://"$peer_secret_file"
unset peer_1_secret_arn
```

Repeat with a different key for `peer_2`, then remove the temporary files using
the workstation's approved secret-cleanup process.

## 3. Prepare management state

The current management datastore lives inside a Docker volume on the old root
disk. Therefore, a snapshot of that whole root disk is not a directly compatible
value for `management_data_snapshot_id`.

For an existing deployment, restore the following to the new dedicated data
volume before enabling management bootstrap:

- NetBird management state into `/srv/netbird/management`;
- Caddy state into `/srv/netbird/caddy-data` and
  `/srv/netbird/caddy-config` to retain the existing ACME account/certificates
  for pre-cutover HTTPS validation, unless another approved certificate method
  is in place;
- the same datastore encryption key in the new management secret.

The SQLite/control-plane copy must use an approved consistency procedure: quiesce
the old writer, create and hash the backup, restore it, validate ownership and
bytes, then retain the old host and backup for rollback. Keep the old writer
stopped from the final copy through management EIP cutover; restarting both
control planes creates divergent state. This module does not stop the old stack
or copy its data automatically.

For a genuinely new NetBird control plane, leave the data volume empty. Do not
confuse that outcome with a migration of the live peer, policy, user, or route
state.

## 4. Bootstrap management only

Enable management only after its secret and data are ready:

```hcl
bootstrap_enabled = {
  management = true
  peer_1     = false
  peer_2     = false
}
```

Review and apply. The SSM association installs Docker and a checksum-verified
ARM64 Compose plugin, mounts the management volume, renders root-only runtime
files, validates Caddy/Compose, starts the seven pinned services, and succeeds
only when all seven remain running.

Keep both peer bootstraps `false` at this stage. Public DNS and the management
EIP still lead to the old control plane; enrolling a peer now would target the
wrong writer. Terraform rejects peer bootstrap until it observes the management
EIP on the new management instance.

## 5. Verify management before cutover

At minimum, collect these readbacks through Session Manager:

```sh
uname -m
free -h
swapon --show
```

On management:

```sh
cd /opt/sleek-netbird
docker compose config --quiet
docker compose ps
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile
```

Read `temporary_public_ip` from `terraform output -json instances`. With the
copied Caddy certificate state, verify the new management host without changing
public DNS or the EIP:

```sh
curl -sS -o /dev/null -D - \
  --resolve nbvpn.sleek.com:443:MANAGEMENT_TEMPORARY_IP \
  https://nbvpn.sleek.com/healthz
curl -sS -o /dev/null -D - \
  -H 'Host: attacker.invalid' \
  http://MANAGEMENT_TEMPORARY_IP/
```

The HTTPS health request must return `401`; the HTTP request must return `308`
with a fixed `Location: https://nbvpn.sleek.com/`. Then run the authenticated
health check without printing its token. An EC2 `running` state or successful
Terraform apply is not workload acceptance.

## 6. Move management, then enroll and move peers

Immediately before each move, refresh and record the current EIP holders:

```sh
terraform plan -refresh-only
terraform output -json observed_eip_holders | jq .
```

Copy the old holder IDs into `eip_rollback_instance_ids`. Then enable exactly one
node and set the exact confirmation phrase:

```hcl
eip_association_enabled = {
  management = true
  peer_1     = false
  peer_2     = false
}

eip_cutover_confirmation = "REASSOCIATE_SLEEK_NETBIRD_EIPS"
```

The reviewed plan must contain exactly one new `aws_eip_association`. Terraform
also requires a successful management bootstrap before this association can be
created. Applying it immediately detaches that EIP from its old instance and
attaches it to the new one. Validate the fixed HTTP redirect and HTTPS controls:

```sh
curl -sS -o /dev/null -D - http://nbvpn.sleek.com/
curl -sS -o /dev/null -D - -H 'Host: attacker.invalid' http://MANAGEMENT_EIP/
curl -sS -o /dev/null -D - https://nbvpn.sleek.com/healthz
```

The two HTTP checks must return `308` with a fixed
`Location: https://nbvpn.sleek.com/...`; the unauthenticated health check must
return `401`. Then verify the authenticated health check without printing its
token.

Only after public DNS reaches the new management instance, enable `peer_1`
bootstrap in a separate reviewed plan:

```hcl
bootstrap_enabled = {
  management = true
  peer_1     = true
  peer_2     = false
}
```

Peer bootstrap downloads the exact signed ARM64 release RPM, verifies both its
pinned SHA-256 and RPM signature, suppresses its premature auto-start scriptlet,
writes a secret-free `default.json`, enables forwarding, passes the key through
a root-only file, deletes that file, and requires
`netbird status --check startup` to succeed.
Verify through Session Manager and in the new NetBird control plane:

```sh
rpm -q netbird
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
netbird status --check live
netbird status --check ready
netbird status --check startup
```

Confirm that the identity is in the intended routing group and that policies do
not grant broader access. Then enable only `peer_1` EIP association, record its
current holder, review, apply, and verify the intended database/resource route,
failover behavior, and public egress IP. Repeat the separate bootstrap,
acceptance, and EIP steps for `peer_2`; keep all previously completed bootstrap
and association booleans `true`.

Do not treat changing an enabled cutover flag back to `false` as rollback: that
only removes Terraform's association and does not restore the old target.
Rollback requires reassociating the allocation ID to the recorded old instance,
verifying service recovery, and reconciling Terraform state before another
apply. For management rollback, stop the new writer first and restore or
reconcile post-copy changes before starting the old writer; never run both
control-plane writers against divergent state.

After all reviewed cutovers, clear `eip_cutover_confirmation`; existing
associations remain managed.

## Capacity and architecture boundary

The requested `t4g.small` has 2 vCPUs and 2 GiB RAM. NetBird's current routing
peer guidance uses 2 vCPUs and 4 GiB as its light-use baseline. Swap and alarms
reduce failure surprise but do not add throughput or replace RAM. Measure CPU,
memory, packet rate, relay use, and route latency under representative load; move
to a 4 GiB Graviton size if memory pressure, swap activity, or sustained CPU
appears.

This module deliberately retains the older multi-container server topology to
avoid combining state migration, ARM64 replatforming, and NetBird's
combined-container migration in one cutover. Track the combined `netbird-server`
and external-database migration separately.

## Local validation

```sh
./scripts/validate.sh
```

This formats-checks and validates Terraform, runs mocked plan tests proving the
default staged deployment and management-before-peer cutover gates, and enforces
the local immutable image/secret-state/redirect invariants. It performs no AWS
apply.
