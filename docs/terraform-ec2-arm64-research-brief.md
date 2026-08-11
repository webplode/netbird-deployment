# Terraform EC2 ARM64 research brief

Date: 2026-08-11

## Recommendation

Build a greenfield Terraform deployment beside the three running instances: one
management node and two routing peers, all on `t4g.small` and Amazon Linux 2023
ARM64. Reuse the existing VPC and two-subnet/two-AZ layout through input
variables. Treat the three existing Elastic IPs as externally owned allocation
IDs and gate each reassociation separately so a normal first apply cannot move
production traffic.

Keep the running seven-service NetBird multi-container topology in this change.
Pin every image to the currently running version and a multi-architecture image
digest, move runtime secrets to AWS Secrets Manager, and provision encrypted
storage, IMDSv2, Systems Manager access, swap, least-privilege security groups,
and repeatable host bootstrap. Migrating the management datastore to NetBird's
new combined-container architecture is a separate control-plane migration, not
an implicit side effect of introducing IaC.

## Repository and live baseline

- **[Local]** Semble found no Terraform or other EC2 IaC implementation in the
  repository. The root Compose deployment is the current implementation seam.
- **[Local]** `deploy/management/` contains the canonical Compose file,
  `Caddyfile`, and companion templates for seven services: Caddy, Dashboard,
  Signal, Relay, Management, OAuth2-Proxy, and Coturn. Several images use moving
  `latest` tags.
- **[Local]** Runtime credentials and state are intentionally ignored, but the
  current host layout materializes credentials in local files consumed by
  Compose.
- **[Local, live read-only]** The current management node is an Ubuntu 24.04
  `t3.small` in `ap-southeast-1a`, with 2 GiB RAM, no swap, a 30 GiB root disk,
  no IAM instance profile, and the stack under `/home/iznogoud/netbird-new`.
- **[Local, live read-only]** The two current peers are Amazon Linux 2023
  `t3.small` nodes running NetBird 0.76.1. They have 2 GiB RAM plus 2 GiB swap
  and occupy separate failure domains in `ap-southeast-1a` and
  `ap-southeast-1b`.
- **[Local, live read-only]** All three instances are x86_64 today. Their active
  network is `vpc-06a3f121e9da3e54c`; management and peer 1 use
  `subnet-06c647986aec0b43d`, while peer 2 uses
  `subnet-0b5848a676b0eb5d7`.
- **[Local, live read-only]** The active service versions are NetBird 0.76.1,
  Dashboard v2.90.9, Caddy 2.11.4, OAuth2-Proxy v7.15.3, and Coturn 4.7.0.
  Registry manifests for every selected image include `linux/arm64`.

## Upstream findings

- **[Upstream]** AWS specifies `t4g.small` as Graviton2/ARM64 with 2 vCPUs and
  2 GiB RAM. The user-selected instance type is therefore architecture
  compatible but below NetBird's current 4 GiB routing-peer baseline.
- **[Upstream]** AWS publishes the current Amazon Linux 2023 ARM64 AMI through
  `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`.
- **[Upstream]** NetBird documents the running multi-container topology as the
  older architecture and recommends the combined `netbird-server` container for
  new deployments. Its migration changes configuration and datastore concerns,
  so combining it with host replatforming would enlarge the failure domain.
- **[Upstream]** NetBird recommends separate failure domains for highly
  available routing peers and requires AWS source/destination checks to be
  disabled when a peer forwards traffic.
- **[Upstream]** NetBird's unattended bootstrap flow keeps the management URL in
  `/var/lib/netbird/default.json`, passes the setup key at runtime (including a
  `--setup-key-file` option), and validates enrollment with
  `netbird status --check startup`.
- **[Local validation]** The documented NetBird RPM repository returned a bad
  repository-metadata signature in a clean Amazon Linux 2023 ARM64 container on
  2026-08-11. The official v0.76.1 GitHub release instead publishes a signed
  ARM64 RPM and SHA-256 digest. The selected bootstrap pins the release asset,
  signing key, and both hashes rather than disabling signature checks.
- **[Upstream]** NetBird peers normally require no public inbound firewall port;
  they initiate connections outbound and use ICE/STUN/relay. The management
  reverse-proxy baseline needs TCP 80/443 and UDP 3478, with this deployment
  additionally retaining UDP 443 for Caddy HTTP/3/native relay traffic.
- **[Upstream]** AWS recommends IMDSv2-only instances and a metadata response hop
  limit of 2 for container hosts. `AmazonSSMManagedInstanceCore` is the supported
  managed policy for Session Manager access.
- **[Upstream]** Secrets Manager retrieval requires
  `secretsmanager:GetSecretValue`; a customer-managed KMS key additionally
  requires `kms:Decrypt`. Terraform's SSM SecureString data source would put
  decrypted values into Terraform state, so it is not suitable here.
- **[Upstream]** The current Terraform AWS provider recommends standalone VPC
  security-group rule resources. `aws_eip_association` is explicitly intended
  for pre-existing EIPs, but reassociation can detach an address from its current
  instance; that action must remain an explicit cutover gate.

## Chosen architecture

1. A single root module under `infra/terraform` owns exactly three EC2
   instances, their security groups, IAM roles/profiles, management data volume,
   empty Secrets Manager containers, alarms, and optional EIP associations.
2. Existing VPC and subnet IDs are inputs. Management and peer 1 may share the
   first subnet; peer 2 uses the second subnet to preserve the observed two-AZ
   failure-domain split.
3. Instance type is fixed to `t4g.small`. The selected AMI is checked to be
   ARM64. Root volumes and the management data volume use encrypted gp3 EBS.
4. Every node requires IMDSv2, disables metadata tags, receives an SSM instance
   profile, and creates 2 GiB swap. SSH ingress is absent by default and can be
   enabled only for explicit administrator CIDRs and a supplied key-pair name.
5. Management receives a separate persistent EBS volume for NetBird and Caddy
   state. Bootstrap renders only non-secret templates from Terraform user data;
   it retrieves runtime values directly from its one Secrets Manager secret.
6. Each peer receives only its own setup-key secret permission. Bootstrap
   verifies the pinned ARM64 RPM hash and signature, suppresses the RPM's
   premature auto-start scriptlet, writes the self-hosted profile atomically,
   then uses a root-only temporary setup-key file and verifies startup. EC2
   source/destination checking is disabled for forwarding.
7. Images use human-readable version tags plus immutable multi-platform digest
   pins. No `latest` image is permitted in the IaC Compose file.
8. EIP allocation IDs are required operator inputs, but association is controlled
   by a per-node boolean map that defaults to `false`. This supports management,
   peer 1, and peer 2 cutover as three independently reviewed actions.
9. Terraform creates secret metadata only; it never creates secret versions or
   accepts secret values as variables. Operators populate values outside
   Terraform after reviewing the generated secret ARNs.

## Alternatives considered

### Migrate to the combined NetBird server now

This is the upstream destination and should be planned, but it changes the
server topology and configuration format while the hosts, CPU architecture,
storage, IAM, and addressing also change. Deferring it keeps rollback and fault
isolation tractable.

### Import and mutate the three running instances

Rejected. The instances are manually configured, x86_64, and currently carry
production control/data-plane traffic. An in-place `t3` to `t4g` conversion is
not possible because the architecture changes. Parallel ARM64 instances permit
verification before any EIP moves.

### Put secret values in Terraform variables or SSM data sources

Rejected. Sensitive Terraform variables still reside in state, and the AWS
provider warns that decrypted SecureString data is stored in raw state. Runtime
instance-role retrieval keeps values outside plans, logs, user data, and state.

## Assumptions and unresolved inputs

- **[Inference]** This request covers implementation in the repository, not an
  immediate apply, live datastore copy, DNS change, peer-group change, or EIP
  reassociation.
- **[Inference]** The current VPC/subnets remain the intended target; the module
  therefore consumes them rather than creating a second network.
- **[Inference]** The current EIPs will remain externally owned and will be
  supplied as allocation IDs. Their current associations are intentionally not
  imported into Terraform.
- **[Inference]** Management datastore migration needs a maintenance window and
  an explicit consistency/rollback procedure. A blank volume is valid for a new
  deployment, but it is not a replacement for the live control-plane state.
- **[Inference]** `t4g.small` is acceptable for present light load because the
  user mandated it. Capacity alarms and a documented scale-up trigger are
  required because it has half the RAM of NetBird's current routing-peer
  baseline.

## Risks and verification gates

- **Capacity:** 2 GiB may exhaust memory under management, relay, or routing
  load. Add swap and CPU/status alarms; monitor memory at runtime and promote to
  a 4 GiB Graviton size if pressure appears.
- **ARM64 compatibility:** Manifest presence proves image availability, not full
  workload behavior. Validate the full Compose stack and both peer health checks
  on the new nodes before any address moves.
- **State consistency:** Copying a live SQLite/control-plane datastore without a
  quiesced snapshot can corrupt or lose changes. Cutover requires an approved
  stop, backup, restore, hash/readback, and rollback window.
- **EIP outage:** Reassociation is immediately traffic-affecting. Review one
  new map entry per plan, move management only after local service checks pass,
  and do not enroll new peers until the management EIP is observed on the new
  control plane. Move and verify peer EIPs one at a time afterward.
- **Bootstrap timing:** Empty secret containers intentionally leave workload
  bootstrap retrying. A successful EC2 state alone is not acceptance; require
  Systems Manager online, cloud-init success, Compose health, HTTPS controls,
  and `netbird status --check startup`.
- **Legacy topology:** Digest pins stabilize the current stack but do not make
  the older architecture a long-term target. Track combined-container migration
  independently.

## Source pack

- [AWS general-purpose instance specifications](https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html)
  — `t4g.small` CPU, memory, and Graviton architecture.
- [AWS public AL2023 AMI parameters](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-ami.html)
  — supported ARM64 AMI lookup path.
- [AWS IMDS options](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-new-instances.html)
  — IMDSv2 and container-host hop-limit guidance.
- [AWS AmazonSSMManagedInstanceCore policy](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html)
  — supported managed-node permissions.
- [AWS Secrets Manager GetSecretValue](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html)
  — runtime secret and KMS permissions.
- [Terraform AWS instance resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance)
  — metadata, EBS, and user-data lifecycle behavior.
- [Terraform EIP association resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip_association)
  — pre-existing EIP reassociation semantics.
- [Terraform standalone security-group rules](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule)
  — current rule-management pattern.
- [NetBird advanced self-hosting guide](https://docs.netbird.io/selfhosted/selfhosted-guide)
  — legacy multi-container warning and public ports.
- [NetBird peer bootstrap](https://docs.netbird.io/manage/peers/bootstrap-via-config-file)
  — default profile, setup-key file, and startup checks.
- [NetBird Linux installation](https://docs.netbird.io/get-started/install/linux)
  — official RPM repository and signing-key configuration.
- [NetBird v0.76.1 release](https://github.com/netbirdio/netbird/releases/tag/v0.76.1)
  — pinned ARM64 RPM release asset and digest provenance.
- [NetBird routing-peer operation](https://docs.netbird.io/manage/networks/how-routing-peers-work)
  — forwarding and failure-domain behavior.
- [NetBird routing-peer sizing](https://docs.netbird.io/manage/networks/sizing-routing-peers)
  — 2 vCPU/4 GiB baseline and measurement guidance.
- [NetBird ports and firewalls](https://docs.netbird.io/about-netbird/ports-and-firewalls)
  — no ordinary inbound peer port requirement.
