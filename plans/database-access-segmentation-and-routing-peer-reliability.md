# Database access segmentation and routing-peer reliability plan

Status: Phase 3 staging objects created; policies and routing-peer assignments not created
Prepared: 2026-08-06
Scope: public RDS and MongoDB Atlas endpoints reached through NetBird; private
VPC access is explicitly out of scope

## 1. Outcome

Replace the current broad mixed-resource topology with a small, explicit,
environment-separated database topology:

- staging users can reach only approved staging/non-production database FQDNs;
- production users can reach only approved production database FQDNs;
- access is limited to the actual database ports;
- public database traffic exits through stable, allow-listed routing-peer
  public IPs;
- EC2 DNS resources and broad provider wildcards no longer inflate each peer's
  route map;
- routing has capacity headroom, redundancy, health checks, and a tested
  rollback path.

No VPC peering, private RDS addressing, private Atlas endpoints, or private
network redesign is part of this job.

## 2. Why this work is needed

### Incident evidence

The routing peer at `100.64.211.11` is a `t3.micro` with 912 MiB usable RAM and
no swap. At the 2026-08-06 read-only inspection it ran NetBird `0.76.1`, was
responsive after reboot, and used approximately 130 MiB RSS.

The important historical evidence is not an OOM kill:

- no OOM or kernel hung-task record was found for the previous boot;
- NetBird failed to stop within systemd's 90-second timeout before the reboot;
- it timed out and required SIGKILL again twice after reboot during restart
  attempts;
- one post-reboot process accumulated about 15 minutes of CPU in 39 minutes;
- the client log showed repeated DNS repair, peer connection churn, relay
  reconnects, and handshake retries;
- the service is currently healthy, so the original blocked goroutine or
  syscall cannot be recovered from the restarted process.

Conclusion: a NetBird shutdown hang is confirmed, but the exact blocked code
path is no longer observable. Large policy state, frequent DNS/connection work,
and the undersized single host are credible contributing factors. Do not label
this as a proven OOM incident.

Current NetBird documentation describes 2 vCPU and 4 GB RAM as a good simple
routing-peer baseline. A `t3.micro` has 2 vCPU but only 1 GB RAM, leaving little
headroom for route updates, DNS state, connection churn, logging, and operating
system cache.

### Live API snapshot

The following was read from the NetBird API at `2026-08-06T07:21:17Z`. IDs and
counts must be refreshed at the beginning of implementation because they can
drift.

| Item | Current value |
| --- | ---: |
| Networks | 6 |
| Network resources | 433 |
| EC2 private-DNS resources | 290 |
| Exact database FQDN resources | 132 |
| Broad database wildcard resources | 2 |
| Groups | 12 |
| Policies | 5 |
| Peers | 35 total, 14 connected |
| Users | 33 |
| Network routers | 4 |

Resource distribution:

| Network | Total | EC2 | RDS | MongoDB | Other |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Sleek PROD Resources` | 208 | 147 | 37 | 24 | 0 |
| `Sleek NONPROD Resources` | 214 | 143 | 60 | 11 | 0 |
| `Sleek Restricted Resources PROD` | 9 | 0 | 1 wildcard | 1 wildcard | 7 |
| `UK - eu-west-2 - Staging VPC` | 1 | 0 | 0 | 0 | 1 |
| `Sleek Internal` | 1 | 0 | 0 | 0 | 1 |
| `Sleek Restricted Resources STAGING` | 0 | 0 | 0 | 0 | 0 |

### Confirmed inventory amendments

The operator confirmed these additional RDS endpoint names for the desired-state
inventory. They were not present in the current Steampipe RDS snapshot and must
be re-verified against the owning AWS account before mutation; engine and
listener port remain pending AWS verification.

| Environment | RDS endpoint |
| --- | --- |
| PROD | `sleek-sign-prod.ciil5xcx68yz.ap-southeast-1.rds.amazonaws.com` |
| STAGING | `sleek-sign-db-staging.ciil5xcx68yz.ap-southeast-1.rds.amazonaws.com` |

### Staging execution record

On 2026-08-06, the following live objects were created without changing any
access policy or routing-peer assignment:

- Networks: `Sleek Databases PROD` and `Sleek Databases STAGING`.
- Destination resource groups: six environment/engine groups for PostgreSQL,
  MySQL, and MongoDB.
- Resources: 133 total—58 PROD and 75 STAGING/NONPROD.
- PROD: 34 PostgreSQL, 4 MySQL, and 20 public MongoDB domains.
- STAGING/NONPROD: 53 PostgreSQL, 6 MySQL, and 16 public MongoDB domains.
- PrivateLink MongoDB domains were excluded because private endpoints are out of
  scope. The two operator-supplied RDS endpoints are staged in PostgreSQL
  groups until their AWS engine and listener ports are verified.

The new Networks have zero routers and zero policies. Global verification after
creation remained at 2 policies, 1 router, and 35 peers. No source identity
groups or access policies were created.
The refreshed staged inventory contains 133 exact public database FQDN
resources: 58 production and 75 staging/non-production. Counts are a current
snapshot and must be refreshed before policy enablement.

### Current access-control defects

The current source groups do not create a clean environment boundary:

- `NetBird VPN Production Users`: 30 peers;
- `NetBird VPN Staging Users`: 30 peers;
- 28 peers are in both groups;
- only two peers are unique to either group.

The enabled production policy also explicitly grants the production source
group access to both `Sleek Prod VPN Resources` and
`Sleek NonProd VPN Resources`. The enabled staging policy grants staging access
to non-production resources. Both include the shared protected-domain group
and allow TCP `80`, `443`, `3306`, `5432`, `27017`, and `27018`.

This means policy names imply stronger separation than the effective group
membership and rule destinations provide.

### Why broad wildcards are not the answer

Do not retain `*.rds.amazonaws.com` or `*.mongodb.net` as an optimization.

- An RDS suffix is shared across AWS customers and accounts, so it cannot
  express Sleek ownership or PROD/STAGING intent.
- `*.mongodb.net` spans unrelated Atlas projects and environments.
- A wildcard matches every subdomain but not the base domain.
- NetBird requires routing-peer DNS resolution for wildcard resources.
- NetBird warns that domain/wildcard policies can interact unexpectedly with
  IP-range resources and recommends dedicated domain networks and routing
  peers.
- Fewer policy objects would be gained at the cost of a much larger security
  blast radius and weaker auditability.

Use exact FQDN resources. A narrower Atlas project-specific wildcard may be
considered later only if that DNS zone is proven to be owned exclusively by
one environment, its apex behavior is handled, and Security approves the
broader match. It is not part of the initial migration.

## 3. Target NetBird model

### Networks

Create two domain-only Networks:

| Network | Contents | Routing peer group |
| --- | --- | --- |
| `Sleek Databases PROD` | Exact production RDS and Atlas FQDNs only | `Sleek DB Routers PROD` |
| `Sleek Databases STAGING` | Exact staging, SIT, dev, and non-production RDS and Atlas FQDNs only | `Sleek DB Routers STAGING` |

Do not mix EC2 names, CIDRs, exit-node routes, internal domains, or protected
websites into these Networks.

### Destination resource groups

Create destination groups by environment and listener class:

- `Sleek DB PROD PostgreSQL`
- `Sleek DB PROD MySQL`
- `Sleek DB PROD MongoDB`
- `Sleek DB STAGING PostgreSQL`
- `Sleek DB STAGING MySQL`
- `Sleek DB STAGING MongoDB`
- additional environment-specific custom-port groups only when inventory proves
  they are required

Every database FQDN must belong to exactly one environment and the smallest
applicable listener group. This prevents the union of PostgreSQL, MySQL, and
MongoDB ports from being allowed to every database. Unclassified inventory is
denied and placed in an exception report; it is not silently added to staging.

### Source identity groups

Use IdP-managed groups as the authority:

- `NetBird DB Production Users`
- `NetBird DB Staging Users`
- optional `NetBird DB Breakglass Administrators`

Requirements:

1. Production and staging membership must be independent and owner-approved.
2. Ordinary users must not be in both groups by default.
3. A user who genuinely needs both receives both deliberately and appears in a
   reviewed exception list.
4. Break-glass membership must be minimal, MFA-protected, time-bounded where
   possible, and reviewed after every use.
5. Test peer membership after IdP/JWT synchronization; a group existing in the
   dashboard does not prove the intended peers received it.

The current 28-peer overlap must be resolved before either new policy is
enabled. This is the primary access-control gate.

### Policies

Create policies disabled, validate their exact API representation, and then
enable them one environment at a time.

| Policy | Source | Rule destinations and ports |
| --- | --- | --- |
| `Allow DB STAGING` | `NetBird DB Staging Users` | Separate rules to STAGING PostgreSQL on TCP 5432, STAGING MySQL on TCP 3306, and STAGING MongoDB on approved Atlas ports |
| `Allow DB PROD` | `NetBird DB Production Users` | Separate rules to PROD PostgreSQL on TCP 5432, PROD MySQL on TCP 3306, and PROD MongoDB on approved Atlas ports |
| `Allow DB breakglass` | break-glass group | Equivalent explicit environment/engine rules; policy disabled until an approved incident |

Use unidirectional `accept` rules. Do not include `All`, the old PROD/NONPROD
groups, web ports, SSH, ICMP, or the routing-peer groups unless a separate
documented requirement exists.

The implementation inventory must derive each RDS instance's actual listener
port and engine. Expected defaults are TCP 5432 for PostgreSQL, 3306 for MySQL
or MariaDB, and 27017/27018 only where Atlas topology requires them. A
non-default listener gets its own narrowly scoped destination group and rule.
Do not blindly copy the current six-port policy to every resource. DNS
resolution is not a reason to grant destination TCP/UDP 53 to the databases.

### Routing peers and public egress

Because database access must use public endpoints, each routing peer needs:

- reliable public internet and DNS resolution;
- an Elastic IP or another stable public egress IP;
- that public IP allow-listed in RDS security groups and the MongoDB Atlas IP
  access list;
- masquerading enabled so database services see the routing peer's approved
  public address;
- no broad inbound Internet exposure; administer through SSM or a narrowly
  controlled NetBird peer policy;
- a setup-key registration scoped only to its router group, with expiration
  and usage limits applied during provisioning.

Recommended capacity and availability:

1. Use `t3.medium` or an equivalent 2 vCPU/4 GB instance as the minimum initial
   size, then resize from observed throughput and memory.
2. Provide two routing peers per environment in separate availability zones.
3. Assign both peers through the environment's router group so NetBird can
   provide failover/load distribution.
4. Give every peer its own stable allow-listed public IP.

A lower-cost transitional option is two 4 GB peers shared by both domain-only
Networks. It still removes EC2 routes and the single-host failure, but it keeps
PROD and STAGING in one routing failure domain. Use it only as an explicitly
accepted temporary compromise.

## 4. Control-plane changes required before migration

The current app is useful for discovery and preview-first creation, but it is
not yet a desired-state reconciler. Before using it for this migration:

1. Add an export command or endpoint that records networks, resources, groups,
   routers, policies, IDs, and associations without secrets.
2. Add a versioned desired-state manifest for exact database FQDN,
   environment, engine, port, network, and destination group.
3. Change duplicate handling so an existing resource missing the intended
   resource group is reported as drift and can be safely reconciled. The
   current behavior skips duplicates without attaching the missing group.
4. Persist operation results and idempotency state outside the Node process;
   the current locks are process-local only.
5. Add preview support for updates and deletions. Deletion must remain a
   separate, explicit, approval-gated phase.
6. Add invariants that reject broad provider wildcards, unclassified
   resources, cross-environment group attachment, and a policy whose source or
   destination crosses the selected environment.
7. Add a source-group overlap report and fail the PROD/STAGING rollout gate
   when an unapproved peer is in both groups.
8. After every mutation, read the NetBird API back and compare it with the
   desired manifest. UI success alone is insufficient.

Steampipe remains the discovery source. Store migration runs and reconciliation
state in an owned PostgreSQL schema rather than treating Steampipe's cache as
the durable control database.

## 5. Migration sequence

### Phase 0 — Freeze, inventory, and rollback package

1. Announce a change window and resource owner for each environment.
2. Export the complete current NetBird API state and a redacted resource list.
3. Capture current group memberships from the IdP and NetBird.
4. Record routing-peer instance IDs, NetBird peer IDs, Elastic IPs, AMI, NetBird
   version, service unit, and security-group/Atlas allow-list state.
5. Store the exact current policy bodies so they can be re-enabled unchanged.
6. Confirm current database endpoints with AWS and Atlas owners; mark deleted,
   restored, test, and unknown clusters for exclusion or explicit approval.
7. Do not delete anything in this phase.

Gate P0: inventory owners sign off, no resource is unclassified, and the
rollback export is readable and complete.

### Phase 1 — Repair identity boundaries

1. Create or select authoritative IdP groups for DB PROD and DB STAGING.
2. Map them into NetBird JWT groups.
3. Remove accidental dual membership; document approved exceptions.
4. Sign in one staging canary and one production canary, then verify their
   actual peer-group assignments through the NetBird API.

Gate P1: zero unapproved overlap and both canaries have exactly the intended
source group.

### Phase 2 — Provision reliable routing peers

1. Create the environment router groups.
2. Provision at least two 4 GB peers per environment, or record approval for
   the temporary shared-pair option.
3. Attach stable public IPs and add all of them to RDS and Atlas allow lists.
4. Install the pinned NetBird client version with scoped setup keys.
5. Verify each peer independently resolves and reaches only the required public
   database endpoints from its operating-system network namespace.
6. Enable NetBird routing-peer disconnected notifications.

Gate P2: both peers in an environment pass DNS and TCP checks and either peer
can be removed from service without losing the canary path.

### Phase 3 — Create target objects without user access

1. Create both domain-only Networks and environment/engine destination groups.
2. Populate exact approved FQDNs from the desired-state manifest.
3. Attach the correct routing-peer group to each Network.
4. Create both access policies disabled.
5. Read the API back and compare counts, FQDNs, groups, ports, routers, and
   enabled flags against the manifest.

Gate P3: 61 expected PROD and 71 expected STAGING/NONPROD entries are reconciled
against a fresh inventory, with any drift explicitly resolved. These are
snapshot counts, not permanent constants.

### Phase 4 — Staging canary and cutover

1. Enable only `Allow DB STAGING` for the staging canary group.
2. Confirm allowed access to representative PostgreSQL/MySQL/Atlas endpoints.
3. Confirm denial for production endpoints, arbitrary RDS endpoints, arbitrary
   Atlas endpoints, EC2 private DNS names, and the routing peer's own services.
4. Test DNS changes while a connection is established and after reconnect.
5. Fail one routing peer and confirm the second takes over.
6. Expand staging membership in controlled batches.
7. Disable the old staging policy only after all staging tests pass.

Gate P4: positive and negative tests pass, HA works, and no old policy is needed
for staging users.

### Phase 5 — Production canary and cutover

Repeat Phase 4 with a small production canary group and production-owned test
queries. A production canary must be denied staging unless that user has an
approved dual-environment exception.

Gate P5: owner-approved production access and denial tests pass, then the old
production policy is disabled.

### Phase 6 — Reduce and retire legacy state

After a minimum observation period:

1. Re-export live API state and compare it with the rollback package.
2. Delete the 290 EC2 resources only after confirming no separate consumer or
   policy requires them.
3. Delete `*.rds.amazonaws.com` and `*.mongodb.net`.
4. Remove migrated exact database resources from the legacy mixed Networks.
5. Remove obsolete legacy destination groups and policies only after their
   dependency lists are empty.
6. Retire empty legacy Networks and their router assignments last.

Every delete batch must have an exact target list, preview, approval, API
readback, and stop-on-first-unexpected-result behavior. Never use name-pattern
mass deletion without matching stable IDs from the approved manifest.

## 6. Verification matrix

Run from one staging-only peer, one production-only peer, one approved
dual-access/break-glass peer if it exists, and an unauthorized peer.

| Test | Staging peer | Production peer | Unauthorized peer |
| --- | --- | --- | --- |
| Approved STAGING RDS/Atlas | Allow | Deny | Deny |
| Approved PROD RDS/Atlas | Deny | Allow | Deny |
| Unlisted `*.rds.amazonaws.com` | Deny | Deny | Deny |
| Unlisted `*.mongodb.net` | Deny | Deny | Deny |
| Removed EC2 private DNS | No NetBird route | No NetBird route | No route |
| Routing peer SSH/host services | Deny unless separately authorized | Same | Deny |

For each approved endpoint:

1. Resolve it and record the answer without credentials.
2. Confirm the expected NetBird route is present.
3. Test the exact TCP listener with `nc -vz` or an equivalent bounded probe.
4. Perform an application-level read-only database login using a dedicated test
   account where available.
5. Record the egress public IP observed by the database control plane.
6. Confirm a non-approved port is denied.

Do not use `ping` as the primary resource test; ICMP has separate policy
semantics and many managed databases do not answer it.

## 7. Reliability controls

### Capacity and service behavior

- Start at 4 GB RAM and keep at least 50% steady-state memory headroom.
- Alert at 70% memory for 15 minutes and 85% immediately.
- Track CPU credit balance if burstable instances remain in use.
- Keep at least 20% disk free.
- Add a bounded health probe around `netbird status`; alert after one timeout
  and restart the service only after repeated failures under an approved
  automation policy.
- Treat any systemd stop timeout or SIGKILL as an incident signal, even if the
  automatic restart succeeds.
- Do not increase `TimeoutStopSec` as the primary fix; that hides the symptom.

### Logs and observability

- Add log rotation for `/var/log/netbird/client.log`; it was already 13.7 MB at
  inspection and the service writes directly to files rather than journald.
- Collect NetBird service state, CLI response latency, RSS, CPU, file size,
  restart count, DNS repair frequency, relay reconnects, and WireGuard
  handshake timeouts.
- Enable NetBird routing-peer disconnected notifications to Slack or the
  incident channel.
- Poll the API for resource counts, disabled routers, disabled policies, and
  PROD/STAGING source-group overlap.
- Preserve at least one pre-restart goroutine/debug bundle during a future hang
  if the CLI can produce it within a strict timeout; never wait indefinitely on
  the same hung daemon.

### Change control

- Pin and canary NetBird client upgrades; the current account has clients from
  `0.70.5` through `0.76.1`.
- Roll out one routing peer, then one canary user group, before broad changes.
- Enforce maximum resource-count and group-overlap checks in CI or the control
  plane before mutations.
- Review resource inventory monthly and expire ownerless entries.

## 8. Rollback

Until both environment cutovers pass their observation window, keep legacy
objects disabled but intact.

Rollback order:

1. Disable the new environment policy.
2. Re-enable the exact exported legacy policy body.
3. Restore source-group membership from the approved snapshot if identity
   changes caused the failure.
4. Re-enable the previous router assignment if the new peers failed.
5. Read the API back and run the old path's positive tests.
6. Investigate before attempting the new cutover again.

If legacy resources have already been deleted, recreate them only from the
versioned export with stable environment classification and explicit approval;
do not reconstruct them from memory or wildcard patterns.

## 9. Acceptance criteria

The job is complete only when all of the following are proven with fresh
evidence:

- 0 unapproved peers are in both DB PROD and DB STAGING source groups.
- Staging-only, production-only, and unauthorized negative tests all pass.
- Every approved exact FQDN is in exactly one environment and the correct
  engine/custom-port destination group.
- No `*.rds.amazonaws.com` or `*.mongodb.net` resource remains.
- No EC2 private-DNS resource remains in the database Networks.
- Policies expose only owner-approved database ports.
- Each environment has two healthy routing peers, or a signed temporary-risk
  acceptance documents the shared-pair design.
- Both public egress IPs per environment are allow-listed and tested.
- A single routing-peer failure does not interrupt the canary path.
- `netbird status` responds within five seconds under normal load.
- No systemd stop timeout, forced SIGKILL, or unexplained service hang occurs
  during a seven-day observation window.
- Monitoring, log rotation, disconnected-peer notifications, and runbooks are
  active.
- The final API export matches the approved desired-state manifest.

## 10. Explicit decisions still required at execution time

The approved architecture does not authorize guessing these values:

1. Named owners and members of DB PROD, DB STAGING, and break-glass groups.
2. Whether the temporary two-peer shared-router option is acceptable or four
   environment-dedicated peers are required immediately.
3. Exact RDS engine/port and Atlas port requirements per resource.
4. Which restored, test, SIT, and unclassified database endpoints remain in
   scope.
5. Observation-window length before destructive legacy cleanup; seven days is
   the recommended minimum.


## 11. Recorded networking decision

Decision recorded 2026-08-07:

- Keep the one-ENI public-subnet design for both NetBird routing peers.
- Give each routing peer its own stable Elastic IP so NetBird can use direct
  peer-to-peer WireGuard connectivity without routing overlay traffic through a
  NAT Gateway or relay by design.
- Do not implement the two-ENI plus Linux policy-routing design for this
  rollout. It would add operational complexity and NAT Gateway data-processing
  cost without being necessary for the selected P2P architecture.
- Request an increase to the EC2-VPC Elastic IP quota in `ap-southeast-1`,
  allocate one EIP per routing peer, and allow-list both EIPs at RDS and Atlas.
- Do not treat auto-assigned public IPv4 addresses as the database allow-list
  identity; they remain only a temporary connectivity state until the EIPs are
  attached.

The quota request is for Amazon EC2 quota `L-0263D0A3` (Elastic IP addresses per
Region). Associate EIPs one peer at a time and verify NetBird P2P recovery,
DNS resolution, routing, and external database source-IP visibility after each
association.

## 12. Primary references

- NetBird Networks: <https://docs.netbird.io/manage/networks>
- Accessing domains and wildcard domains:
  <https://docs.netbird.io/manage/networks/use-cases/by-resource-type/accessing-entire-domains-within-networks>
- Routing peer behavior and domain/IP isolation:
  <https://docs.netbird.io/manage/networks/how-routing-peers-work>
- Groups and access policies:
  <https://docs.netbird.io/manage/access-control/manage-network-access>
- Internal DNS servers and wildcard behavior:
  <https://docs.netbird.io/manage/dns/internal-dns-servers>
