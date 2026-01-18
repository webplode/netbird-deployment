# NetBird Two-EC2 Deployment (Split Management + Router)

This version separates the management plane (UI/API) from the routing plane.

- **EC2-A (Public)**: Caddy + OAuth2-Proxy + NetBird Management/Signal/Relay/Dashboard
- **EC2-B (Private or Public)**: NetBird client only, used as VPC router

---

## Architecture

```
                         INTERNET
                             |
                             v
               +---------------------------+
               | EC2-A (Public subnet)     |
               | Management plane          |
               |---------------------------|
               | Caddy (TLS)               |
               | OAuth2-Proxy              |
               | Dashboard                 |
               | Management                |
               | Signal                    |
               | Relay                     |
               | Coturn                    |
               +--------------+------------+
                              |
                              | NetBird control plane
                              v
               +---------------------------+
               | EC2-B (Private subnet)    |
               | Router only               |
               | NetBird client (peer)     |
               +--------------+------------+
                              |
                              | VPC Peering
                              v
               +---------------------------+
               | 10.2.0.0/16 10.4.0.0/16   |
               +---------------------------+
```

---

## 1) Why split?

Split is recommended when:
- You want a hardened management plane
- You need a private router with no public exposure
- You plan to scale routing (multiple routers for prod/staging)

Single EC2 is simpler and cheaper. Split adds isolation and easier scaling.

---

## 2) AWS Setup

### 2.1 EC2-A (Management plane)
- Public subnet
- Elastic IP
- Security group (Inbound):
  - TCP 80, 443
  - UDP 443 (optional HTTP/3)
  - UDP/TCP 3478, TCP 5349, UDP 49152-65535 (Coturn)
  - TCP 22 from your IP

### 2.2 EC2-B (Router)
- Private subnet (recommended)
- No public IP
- Security group (Inbound):
  - Allow all from Hub VPC CIDR
  - SSH from bastion or SSM

### 2.3 Routing prerequisites
- Disable source/destination check on EC2-B
- Ensure EC2-B has outbound internet (NAT Gateway) to reach `https://netbird.example.com`

### 2.4 DNS
`netbird.example.com -> EC2-A Elastic IP`

---

## 3) EC2-A Deployment (Management Plane)

Follow the **Single EC2 guide** steps for:
- Docker, Caddy, OAuth2-Proxy
- JumpCloud OIDC apps
- `.env`, `Caddyfile`, `management.json`

Only difference: **do not install the NetBird client on EC2-A for routing**.

---

## 4) EC2-B Router Setup

### 4.1 Install NetBird client
```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh
sudo netbird up --management-url https://netbird.example.com
sudo netbird status
```

### 4.2 Enable IP forwarding
```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 4.3 NAT configuration
```bash
sudo iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -o eth0 -j MASQUERADE
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

---

## 5) AWS Routing

### 5.1 Hub VPC Route Table
Add:
- `100.64.0.0/10` -> EC2-B ENI

### 5.2 Peered VPC Route Tables
Add:
- `100.64.0.0/10` -> VPC Peering Connection to Hub VPC

---

## 6) NetBird Dashboard Configuration

1) Create routes for each VPC CIDR
2) Assign routes to **EC2-B router peer**
3) Create user groups (Admins, Prod, Staging)
4) Create access policies mapping groups to routes

---

## 7) Scaling Routes (Optional)

For staging and prod, you can run **two routers**:
- EC2-B (staging router)
- EC2-C (prod router)

Then create separate routes and access policies per environment.

---

## 8) Testing

- Login to `https://netbird.example.com`
- Verify EC2-B appears as a peer
- Test route access from a client:
```bash
netbird up --management-url https://netbird.example.com
ping 10.2.0.1
```

---

## 8.1) CrowdSec Firewall Bouncer (Host Install)

Install the firewall bouncer on **EC2-A** (management plane) so it can attach to
`INPUT` and `DOCKER-USER` and protect exposed container ports.

Docs: https://docs.crowdsec.net/u/bouncers/firewall

1) Generate the bouncer API key:
```bash
docker compose exec crowdsec cscli bouncers add firewall-bouncer
```

2) Install the bouncer on Ubuntu:
```bash
sudo apt install crowdsec-firewall-bouncer-iptables
```

3) Configure the bouncer:
- `api_url`: `http://127.0.0.1:8080`
- `api_key`: use the key you generated
- `iptables_chains`: include `INPUT` and `DOCKER-USER`

Restart the bouncer service after updating its config.

---

## 9) Hardening Checklist (NetBird Docs)

1) **Remove default "allow all" policy** and define group-based access.  
Docs: https://docs.netbird.io/manage/access-control

2) **Use posture checks** for production routes.  
Docs: https://docs.netbird.io/how-to/manage-posture-checks

3) **Limit setup keys** (expiry + usage count).  
Docs: https://docs.netbird.io/manage/peers/register-machines-using-setup-keys

4) **Enable audit/activity logging** and review regularly.  
Docs: https://docs.netbird.io/manage/activity

5) **Restrict NetBird SSH** to approved groups/hosts.  
Docs: https://docs.netbird.io/manage/peers/ssh

6) **Keep reverse proxy TLS-only** and open only required ports.  
Docs: https://docs.netbird.io/selfhosted/selfhosted-guide

7) **Use IdP with MFA** and keep secrets out of git.  
Docs: https://docs.netbird.io/selfhosted/identity-providers

8) **Docker host hardening**: patch OS, restrict SSH, and use `no-new-privileges`.  
Docs: https://docs.netbird.io/get-started/install/docker

---

## Notes

- EC2-A must expose management, signal, and relay endpoints publicly.
- EC2-B can remain private as long as it has outbound access.
- Split model is recommended when you need stricter isolation.
