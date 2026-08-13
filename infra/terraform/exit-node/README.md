# NetBird exit node (standalone)

One `t4g.micro` Amazon Linux 2023 ARM64 instance whose only job is to be a
NetBird exit node. Independent of the three-node module in `infra/terraform`;
it consumes an existing VPC/subnet and enrolls against the existing management
domain.

## What it creates

- One EC2 instance (`t4g.micro` by default), encrypted gp3 root volume,
  IMDSv2-only, 2 GiB swap, source/destination check disabled, unlimited CPU
  credits.
- A security group with **no required inbound rules** (NetBird peers connect
  outbound only; AWS security groups are stateful). One optional rule, on by
  default: UDP 51820 so clients reach WireGuard directly instead of
  hole-punching or relaying (`open_wireguard_port = false` to close it). SSH
  can be opened per admin CIDR, but Session Manager is the default.
- An IAM role/instance profile with `AmazonSSMManagedInstanceCore` plus
  read-only access to exactly one Secrets Manager secret.
- An empty Secrets Manager secret container for the NetBird setup key.
  Terraform never sees the key value.
- Optionally (`create_eip = true`) a dedicated Elastic IP so the egress
  address survives stop/start.

Bootstrap runs as a systemd oneshot installed via user data: it verifies and
installs the pinned NetBird 0.76.1 ARM64 RPM (signature + SHA-256), enables IP
forwarding, writes the self-hosted profile pointing at `var.domain`, fetches
the setup key from Secrets Manager (retrying up to 30 minutes so you can
populate it after apply), joins, and verifies with
`netbird status --check startup`. A reboot re-runs it idempotently.

## Deploy

Prereqs: Terraform ~> 1.15, AWS credentials for the devops account
(e.g. `AWS_PROFILE=DevOpsAdministrator`), and a NetBird **setup key**
(Dashboard → Setup Keys → Create; make it single-use, auto-assign a group such
as `exit-nodes`).

```sh
cd infra/terraform/exit-node
cp terraform.tfvars.example terraform.tfvars   # review values
export AWS_PROFILE=DevOpsAdministrator

terraform init
terraform plan
terraform apply
```

Immediately after apply (the instance retries for 30 minutes), populate the
setup key — the exact command is in the `populate_setup_key_command` output:

```sh
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw setup_key_secret_arn)" \
  --secret-string '<RAW-NETBIRD-SETUP-KEY>' \
  --region ap-southeast-1
```

Prefer zero wait? Create the secret first, populate it, then build the rest:

```sh
terraform apply -target=aws_secretsmanager_secret.setup_key
aws secretsmanager put-secret-value --secret-id ... --secret-string '...'
terraform apply
```

### Make it an exit node

Enrollment only registers a peer. In the NetBird dashboard:

1. Peers → select the new peer (hostname `nb-prod-exitnode-only-01` with the
   example tfvars).
2. Add an exit node route: Networks → Routes → Add route with
   `0.0.0.0/0` (or use the peer's "Set up exit node" shortcut), routing peer =
   this peer, **masquerade enabled**, and the distribution groups that may use
   it.
3. Clients then pick it under Exit node.

### Verify

```sh
aws ssm start-session --target "$(terraform output -raw instance_id)" --region ap-southeast-1
# on the instance:
sudo journalctl -u netbird-exit-node-bootstrap -f
sudo netbird status --detail
```

From a client using the exit node, `curl -4 ifconfig.me` must return the
instance's public address (`public_ipv4_address` output).

## IAM permissions the operator needs

`DevOpsAdministrator` covers everything. A least-privilege deploy policy needs:

- **EC2**: `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:StopInstances`,
  `ec2:StartInstances`, `ec2:Describe*`, `ec2:CreateTags`, `ec2:DeleteTags`,
  `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup`,
  `ec2:AuthorizeSecurityGroup*`, `ec2:RevokeSecurityGroup*`,
  `ec2:ModifyInstanceAttribute` (source/dest check, user data),
  `ec2:ModifyInstanceMetadataOptions`,
  `ec2:AllocateAddress`, `ec2:ReleaseAddress`, `ec2:AssociateAddress`,
  `ec2:DisassociateAddress` (only when `create_eip = true`),
  `ec2:ModifyInstanceCreditSpecification`.
- **IAM**: `iam:CreateRole`, `iam:DeleteRole`, `iam:GetRole`, `iam:TagRole`,
  `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:GetRolePolicy`,
  `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:ListRolePolicies`,
  `iam:ListAttachedRolePolicies`, `iam:ListInstanceProfilesForRole`,
  `iam:CreateInstanceProfile`, `iam:DeleteInstanceProfile`,
  `iam:GetInstanceProfile`, `iam:TagInstanceProfile`,
  `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile`,
  and — the one people forget — `iam:PassRole` on the created role so
  `RunInstances` may attach the instance profile.
- **Secrets Manager**: `secretsmanager:CreateSecret`,
  `secretsmanager:DeleteSecret`, `secretsmanager:DescribeSecret`,
  `secretsmanager:TagResource`, `secretsmanager:GetResourcePolicy`, plus
  `secretsmanager:PutSecretValue` for the one manual populate step.
- **SSM**: `ssm:GetParameter` on
  `/aws/service/ami-amazon-linux-latest/*` (AMI lookup) and
  `ssm:StartSession`/`ssm:TerminateSession` for administration.

The **instance** itself gets only `AmazonSSMManagedInstanceCore` and
`GetSecretValue`/`DescribeSecret` on its own secret (plus `kms:Decrypt` if a
customer-managed key is configured).

## Costs (ap-southeast-1, on-demand)

- `t4g.micro`: ≈ $0.0106/h ≈ **$7.7/month**
- 16 GiB gp3: ≈ **$1.5/month**
- The real cost is **data transfer out**: ≈ $0.12/GB. All client traffic using
  this exit node egresses here.
- Unlimited CPU credits can add surplus charges under sustained CPU load.

## Sizing note

`t4g.micro` has 1 GiB RAM — below NetBird's 2 vCPU/4 GiB routing-peer
baseline. Fine for light personal/egress use; the 2 GiB swap absorbs spikes.
If throughput or memory pressure grows, bump `instance_type` to `t4g.small`
or `t4g.medium` (same module, in-place resize via stop/start).
