# Self-Hosted Netbird Stack with Hardening & Monitoring

This repository contains a reference implementation for a self-hosted **Netbird Management Server** setup using Docker Compose. The configuration focuses on stability, resource efficiency, and compliance with standard infrastructure protection baselines (e.g., aligning with BSI IT-Grundschutz modules for containerization).

It is designed for system administrators in public sector environments or SMEs who require a reliable overlay network without relying on external SaaS control planes.

## Features

- **Full Stack Deployment**: Includes Management, Dashboard, Signal, Relay, and Coturn (STUN/TURN).
- **Advanced Threat Detection**:
  - **CrowdSec IPS**: Integrated Security Engine with **custom parsers** for Netbird Management and Coturn logs.
  - **Firewall Bouncer**: Direct integration with `nftables`/`iptables` to block malicious IPs at the network layer.
  - **Behavioral Analysis**: Custom scenarios to detect auth-brute-forcing and relay abuse.
- **Network Isolation**: Coturn runs with specific port bindings instead of `host` mode to maintain Docker network segregation.
- **Identity Provider**: Supports external OIDC providers (e.g., JumpCloud) with OAuth2-Proxy for admin access.
- **Resource Limits**: Log rotation and container restart policies configured for long-term maintenance-free operation.
- **IPv6 Support**: Configured for dual-stack environments.

## Architecture

The stack consists of the following components:

1. **Caddy**: Reverse Proxy for Dashboard and API endpoints (TLS termination).
2. **Netbird Core**: Management, Signal, and Relay services.
3. **Coturn**: VoIP media relay (TURN/STUN) with restricted port ranges and network isolation.
4. **OAuth2-Proxy**: Protects admin access via OIDC (JumpCloud, Okta, etc.).
5. **CrowdSec Stack**: 
   - **Security Engine**: Reads logs from all containers via `acquis.yaml`.
   - **Firewall Bouncer**: Applies decisions (bans) directly to the host firewall.

## Security Architecture

### CrowdSec Configuration
The stack bridges the gap between application logs and network defense:
1. **Log Acquisition**: Centralized acquisition via `acquis.yaml` mapping container logs to specific labels.
2. **Parsing**: Custom Grok patterns decode Netbird's specific log formats (Go-based logging) and Coturn's STUN/TURN allocation logs.
3. **Remediation**: A host-installed Firewall Bouncer applies blocklists to `INPUT` and `DOCKER-USER`, protecting Docker-published ports.

## Hardening Checklist (NetBird Docs)

Apply these in the NetBird dashboard and at the host level:

1. **Remove default "allow all" policy** and create explicit access policies by group and destination.  
   Docs: https://docs.netbird.io/manage/access-control
2. **Use posture checks** for sensitive routes (client version/OS compliance).  
   Docs: https://docs.netbird.io/how-to/manage-posture-checks
3. **Limit setup keys** with expiration and usage count. Prefer one-time keys.  
   Docs: https://docs.netbird.io/manage/peers/register-machines-using-setup-keys
4. **Enable audit/activity logging** and review regularly.  
   Docs: https://docs.netbird.io/manage/activity
5. **Restrict NetBird SSH** by identity and host/user mapping.  
   Docs: https://docs.netbird.io/manage/peers/ssh
6. **Keep reverse proxy TLS-only** and expose minimal ports.  
   Docs: https://docs.netbird.io/selfhosted/selfhosted-guide
7. **Use external OIDC with MFA** (JumpCloud) and keep secrets off git.  
   Docs: https://docs.netbird.io/selfhosted/identity-providers
8. **Docker host hardening**: patch OS, restrict SSH, and run containers with `no-new-privileges`.  
   Docs: https://docs.netbird.io/get-started/install/docker

### Compliance Notes
- **Log Rotation**: Strict limits (e.g., 50MB) per container to ensure audit trails without disk exhaustion.
- **Privacy**: Parsers are configured to anonymize sensitive user data before processing.

## Prerequisites

- Ubuntu 24.04 LTS (recommended)
- Docker Engine & Docker Compose (v2.0+)
- Public IPv4 and IPv6 address
- DNS records pointing to your server IP (e.g., `netbird.example.com`)

## Quick Start

### 1. Clone the repository
git clone https://github.com/patrick-bloem/Netbird-self-hosted-stack.git
cd Netbird-self-hosted-stack


### 2. Initialize directories
Run the initialization script to create the necessary folder structure, log directories, and placeholder configs.
chmod +x init.sh
./init.sh

### 3. Configuration
Copy the example environment file and adjust the variables to your infrastructure.
cp .env.example .env
nano .env

*Note: Ensure to generate strong secrets for `OAUTH2_COOKIE_SECRET` and any NetBird relay/TURN secrets.*

### 4. Deployment
Start the stack in detached mode.
docker compose up -d

### 5. Post-Deployment: CrowdSec Firewall Bouncer (Host Install)
Install the firewall bouncer on the host using the official instructions. This protects
Docker-published ports by attaching to the `INPUT` and `DOCKER-USER` chains.

Docs: https://docs.crowdsec.net/u/bouncers/firewall

Generate the API key:
docker compose exec crowdsec cscli bouncers add firewall-bouncer

Then configure the bouncer on the host:
- `api_url`: `http://127.0.0.1:8080`
- `api_key`: use the key you generated
- `iptables_chains`: include `INPUT` and `DOCKER-USER`

You can start from the template in this repo:
`config/crowdsec/crowdsec-firewall-bouncer.yaml`

## Admin Access to Management API

NetBird clients must reach the Management API and gRPC endpoints without OAuth2-Proxy.
If you want **admin-only** access to the Management API, add an **admin subdomain**
proxied through OAuth2-Proxy while keeping the public endpoints open for clients.

Recommended approach:
- `netbird.example.com` (public for clients, dashboard protected)
- `admin.netbird.example.com` (admin-only Management API via OAuth2-Proxy)

## Maintenance & Logs

Logs are configured with a `json-file` driver and rotation policies to prevent disk exhaustion.

### Monitoring Security Status
To inspect CrowdSec metrics and active bans:
Show metrics
docker compose exec crowdsec cscli metrics

List active bans
docker compose exec crowdsec cscli decisions list

## Disclaimer

This configuration is provided "as is" for educational and administrative purposes. While it follows general hardening guidelines, please verify against your specific organizational compliance requirements before deploying in production.

---
**Author**: Patrick Bloem
**License**: MIT
