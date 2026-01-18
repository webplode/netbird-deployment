# NetBird Single EC2 Deployment (JumpCloud + Caddy + OAuth2-Proxy)

Single-instance deployment where one EC2 runs the management plane, dashboard, and acts as the router to your peered VPCs.

---

## Architecture

```
                                INTERNET
                                    |
                                    v
                         +--------------------+
                         |     EC2 (Public)   |
                         |  NetBird + Router  |
                         |--------------------|
                         | Caddy (TLS)        |
                         | OAuth2-Proxy       |
                         | Dashboard          |
                         | Management         |
                         | Signal             |
                         | Relay              |
                         | Coturn             |
                         +---------+----------+
                                   |
                                   | VPC Peering
                                   v
                     +-------------------------------+
                     | 10.2.0.0/16 10.4.0.0/16 ...  |
                     +-------------------------------+

VPN Clients -> https://netbird.example.com
```

Protected (OAuth2-Proxy): `/` (Dashboard)
Public (no auth): `/api/*`, `/management.ManagementService/*`, `/signalexchange.SignalExchange/*`, `/relay`

---

## 1) Prerequisites

### Required values
- Domain: `netbird.example.com`
- Elastic IP (EIP)
- AWS Region
- Hub VPC CIDR (example: `10.241.0.0/24`)
- List of peered VPC CIDRs (staging, prod, etc.)

### JumpCloud setup (OIDC)
Create two OIDC apps:

1) **NetBird Dashboard (OAuth2-Proxy)**
   - Redirect URI: `https://netbird.example.com/oauth2/callback`

2) **NetBird Management**
   - Redirect URIs:
     - `https://netbird.example.com/auth`
     - `https://netbird.example.com/silent-auth`
     - `http://localhost:53000`
   - Client Authentication Type: **Client Secret Post**

Collect:
- Dashboard app: Client ID + Client Secret (for OAuth2-Proxy)
- Management app: Client ID + Client Secret (for NetBird management.json)

JumpCloud endpoints:
- Issuer: `https://oauth.id.jumpcloud.com/`
- OIDC discovery: `https://oauth.id.jumpcloud.com/.well-known/openid-configuration`

---

## 2) AWS Setup

### 2.1 Create Security Group (single EC2)
Name: `netbird-server-sg`

Attach this SG to the EC2 that runs the NetBird stack **and** the router client.

#### Inbound rules (Internet-facing, minimum required)
| Type | Protocol | Port | Source | Purpose |
|------|----------|------|--------|---------|
| SSH | TCP | 22 | Your admin IP/32 | Admin access |
| HTTP | TCP | 80 | 0.0.0.0/0 | ACME HTTP-01 + redirect |
| HTTPS | TCP | 443 | 0.0.0.0/0 | Dashboard + Management API + gRPC |
| Custom UDP | UDP | 3478 | 0.0.0.0/0 | STUN |
| Custom TCP | TCP | 3478 | 0.0.0.0/0 | TURN TCP |
| Custom TCP | TCP | 5349 | 0.0.0.0/0 | TURN TLS |
| Custom UDP | UDP | 49152-65535 | 0.0.0.0/0 | TURN relay |

#### Inbound rules (from VPC peering CIDRs)
These allow **return traffic** from your peered VPCs to reach NetBird clients.

Add **All traffic** rules for each peered CIDR:

| Type | Protocol | Port | Source | Purpose |
|------|----------|------|--------|---------|
| All traffic | All | All | 10.2.0.0/16 | Peered VPC |
| All traffic | All | All | 10.4.0.0/16 | Peered VPC |
| All traffic | All | All | 10.32.0.0/16 | Peered VPC |
| All traffic | All | All | 10.12.0.0/16 | Peered VPC |
| All traffic | All | All | 10.22.0.0/16 | Peered VPC |
| All traffic | All | All | 10.1.0.0/16 | Peered VPC |

If you later add more peering connections, repeat the same rule per CIDR.

#### Optional inbound rules (only if you need them)
- UDP 443: enable only if you plan to use HTTP/3 in Caddy
- UDP 51820: only if you run a standalone WireGuard service (NetBird does not require it)

#### Outbound rules
Keep the default **All traffic → 0.0.0.0/0**. The instance must reach:
- JumpCloud (OIDC)
- NetBird updates / client downloads
- STUN/TURN clients

If you need to restrict outbound later, ensure these are still reachable.

### 2.2 Launch EC2
- Ubuntu 24.04 LTS
- t3.small (no Zitadel/Postgres)
- 20 GB gp3
- Public subnet (Hub VPC)
- Associate Elastic IP
- Disable Source/Destination Check

### 2.3 DNS
Create `A` record:
`netbird.example.com -> <Elastic IP>`

---

## 3) EC2 Setup

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
sudo apt install -y docker-compose-plugin
newgrp docker
```

Enable IP forwarding:
```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## 4) Deploy the Stack

### 4.1 Clone and init
```bash
cd ~
git clone https://github.com/patrick-bloem/Netbird-self-hosted-stack.git
cd Netbird-self-hosted-stack
chmod +x init.sh
./init.sh
```

### 4.2 Generate secrets
```bash
echo "TURN_SECRET=$(openssl rand -base64 32)"
echo "RELAY_SECRET=$(openssl rand -base64 32)"
echo "OAUTH2_COOKIE_SECRET=$(openssl rand -base64 32 | head -c 32)"
```

### 4.3 Configure `.env`
```bash
cp .env.example .env
nano .env
```

Minimal required variables:
```env
DOMAIN=netbird.example.com
PUBLIC_IP=YOUR_EIP

TURN_SECRET=YOUR_TURN_SECRET
RELAY_SECRET=YOUR_RELAY_SECRET

OAUTH2_CLIENT_ID=your-oauth2proxy-client-id
OAUTH2_CLIENT_SECRET=your-oauth2proxy-client-secret
OAUTH2_COOKIE_SECRET=your-cookie-secret

JUMPCLOUD_CLIENT_ID_DASHBOARD=your-mgmt-client-id
JUMPCLOUD_CLIENT_ID_MGMT=your-mgmt-client-id
JUMPCLOUD_CLIENT_SECRET_MGMT=your-mgmt-client-secret

# Optional (if using CrowdSec bouncer)
CROWDSEC_BOUNCER_KEY=
```

### 4.4 Caddyfile
```bash
cp config/Caddyfile.example config/Caddyfile
nano config/Caddyfile
```

Use this:
```caddyfile
netbird.example.com {
    log {
        output file /var/log/caddy/access.log
        format json
    }

    handle /api/* {
        reverse_proxy netbird-management:80
    }

    handle /management.ManagementService/* {
        reverse_proxy h2c://netbird-management:80
    }

    handle /signalexchange.SignalExchange/* {
        reverse_proxy h2c://netbird-signal:80
    }

    handle /relay* {
        reverse_proxy netbird-relay:33080
    }

    handle /oauth2/* {
        reverse_proxy oauth2-proxy:4180
    }

    handle {
        reverse_proxy oauth2-proxy:4180
    }
}
```

### 4.5 Allowed admin emails
```bash
cat > config/allowed_emails.txt << 'EOF'
admin@yourcompany.com
admin2@yourcompany.com
EOF
```

### 4.6 Coturn config
```bash
nano config/turnserver.conf
```

```conf
listening-port=3478
tls-listening-port=5349
min-port=49152
max-port=65535

external-ip=YOUR_EIP
realm=netbird.example.com

fingerprint
lt-cred-mech
use-auth-secret
static-auth-secret=YOUR_TURN_SECRET

log-file=stdout
verbose
no-multicast-peers
no-cli
no-tlsv1
no-tlsv1_1
```

### 4.7 Management config (JumpCloud)
```bash
nano config/management.json
```

```json
{
  "Stuns": [
    { "Proto": "udp", "URI": "stun:netbird.example.com:3478" }
  ],
  "TURNConfig": {
    "Turns": [
      { "Proto": "udp", "URI": "turn:netbird.example.com:3478", "Username": "", "Password": "" }
    ],
    "TimeBasedCredentials": true,
    "CredentialsTTL": "12h",
    "Secret": "YOUR_TURN_SECRET"
  },
  "Relay": {
    "Addresses": ["rels://netbird.example.com:443/relay"],
    "CredentialsTTL": "24h",
    "Secret": "YOUR_RELAY_SECRET"
  },
  "Signal": { "Proto": "https", "URI": "netbird.example.com:443" },
  "HttpConfig": {
    "AuthIssuer": "https://oauth.id.jumpcloud.com/",
    "AuthAudience": "YOUR_JUMPCLOUD_CLIENT_ID_DASHBOARD",
    "OIDCConfigEndpoint": "https://oauth.id.jumpcloud.com/.well-known/openid-configuration"
  },
  "IdpManagerConfig": {
    "ManagerType": "jumpcloud",
    "ClientConfig": {
      "Issuer": "https://oauth.id.jumpcloud.com/",
      "TokenEndpoint": "https://oauth.id.jumpcloud.com/oauth2/token",
      "ClientID": "YOUR_JUMPCLOUD_CLIENT_ID_MGMT",
      "ClientSecret": "YOUR_JUMPCLOUD_CLIENT_SECRET_MGMT",
      "GrantType": "client_credentials"
    }
  },
  "DeviceAuthorizationFlow": {
    "Provider": "hosted",
    "ProviderConfig": {
      "Audience": "YOUR_JUMPCLOUD_CLIENT_ID_DASHBOARD",
      "Domain": "oauth.id.jumpcloud.com",
      "ClientID": "YOUR_JUMPCLOUD_CLIENT_ID_DASHBOARD",
      "TokenEndpoint": "https://oauth.id.jumpcloud.com/oauth2/token",
      "DeviceAuthEndpoint": "https://oauth.id.jumpcloud.com/oauth2/device/authorize",
      "Scope": "openid profile email offline_access",
      "UseIDToken": false
    }
  },
  "PKCEAuthorizationFlow": {
    "ProviderConfig": {
      "Audience": "YOUR_JUMPCLOUD_CLIENT_ID_DASHBOARD",
      "ClientID": "YOUR_JUMPCLOUD_CLIENT_ID_DASHBOARD",
      "AuthorizationEndpoint": "https://oauth.id.jumpcloud.com/oauth2/auth",
      "TokenEndpoint": "https://oauth.id.jumpcloud.com/oauth2/token",
      "Scope": "openid profile email offline_access",
      "RedirectURLs": ["http://localhost:53000"],
      "UseIDToken": false
    }
  }
}
```

### 4.8 Start
```bash
docker compose up -d
docker compose ps
```

---

## 5) Router Setup (same EC2)

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh
sudo netbird up --management-url https://netbird.example.com
sudo netbird status
```

Enable NAT:
```bash
sudo iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -o eth0 -j MASQUERADE
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

---

## 6) AWS Routing (multiple VPC peering)

### 6.1 Hub VPC route table
Add:
- `100.64.0.0/10` -> EC2 ENI

### 6.2 Each peered VPC route table
Add:
- `100.64.0.0/10` -> VPC Peering Connection (to hub)

---

## 7) Dashboard Routes and Policies

1) Create routes for each VPC CIDR
2) Assign the route to the EC2 router peer
3) Create user groups (Admins, Dev, Staging)
4) Create policies so users only see allowed routes

---

## 8) Testing

- Open `https://netbird.example.com` (should require JumpCloud login)
- Connect a client and verify route access:
```bash
netbird up --management-url https://netbird.example.com
netbird status
ping 10.2.0.1
```

---

## Notes

- Caddy is required for routing gRPC and path-based traffic.
- OAuth2-Proxy protects only the dashboard.
- If JumpCloud device auth fails, try `UseIDToken: true` in management.json.
