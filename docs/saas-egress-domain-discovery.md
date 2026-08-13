# SaaS egress domain discovery from HAR captures

How to work out the exact set of domains a SaaS application needs, so those
domains can be added as NetBird domain-based routes (or to an egress
allowlist). Written after doing this for Claude and ChatGPT; the results for
both are recorded at the end.

Use this whenever the ask is some form of *"here are HAR files for
application X, tell me what domains and wildcards to whitelist / route through
NetBird."*

## Procedure

### 1. Capture

HAR files come from the browser devtools Network tab (Firefox or Chromium,
"Save All As HAR") or from the Electron desktop app's devtools. Put them in
`har-files/` at the repo root. `*.har` is gitignored — captures contain live
session cookies and bearer tokens and must never be committed.

Capture more than the happy path. A single logged-in browsing session misses
whole categories of traffic. Aim for:

- cold load with an empty cache
- **a full logout → login cycle** (the flow most often missing, and the one
  where a missing domain locks users out rather than degrading the UI)
- file upload and download
- any feature that streams (WebSocket / SSE)
- the desktop app as well as the browser, if both are in scope

### 2. Extract

```sh
cd har-files
python3 ../tools/har-domain-extract.py .                    # every .har in cwd
OUT_DIR=chatgpt-report python3 ../tools/har-domain-extract.py chatgpt-*.har
```

Stdlib only, no dependencies. Writes to `har-report/` (override with
`OUT_DIR`):

| File | Contents |
| --- | --- |
| `domains.csv` | per-client domain, hits, unique paths, methods, statuses, bytes, source HAR |
| `urls.csv` | every request — full URL, path/query split, status, content-type, bytes, referer/origin, server IP |
| `domains.txt` | plain unique domain list, one per line |

The script splits traffic by User-Agent into `desktop-app` (Electron) and
`browser`, which matters when the two clients hit different backends — they
did for Claude.

### 3. Review the endpoint surface

Group paths after normalising UUIDs and opaque IDs, to see what each domain is
actually for:

```sh
cd har-report
python3 -c "
import csv,re,collections
rows=list(csv.DictReader(open('urls.csv')))
def norm(p):
    p=re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}','{uuid}',p)
    return re.sub(r'/[A-Za-z0-9_-]{22,}','/{id}',p)
c=collections.Counter((r['domain'],norm(r['path'])) for r in rows)
for (d,p),n in sorted(c.items()): print(f'{n:>4}  {d}{p}')
"
```

Classify each domain as **functional** (auth, API, assets, WebSocket),
**cosmetic** (favicons, fonts) or **telemetry**. Only functional domains have
to be routed. Telemetry can usually be dropped — see the Datadog note below.

### 4. Scan bundle strings for what the capture missed

Response bodies in the HAR contain the app's JavaScript, which references
hosts the session never actually called. This is how the ChatGPT auth and
upload domains were found despite zero auth requests in the capture:

```sh
python3 - <<'EOF'
import re, collections, io
pat = re.compile(r'(?:https?%3A%2F%2F|https?://|wss://)([a-z0-9.-]+\.[a-z]{2,})', re.I)
hosts = collections.Counter()
for f in ['app-1.har','app-2.har']:
    with io.open(f, encoding='utf-8', errors='replace') as fh:
        for chunk in iter(lambda: fh.read(4_000_000), ''):
            for h in pat.findall(chunk): hosts[h.lower()] += 1
for h,n in sorted(hosts.items(), key=lambda kv:-kv[1]): print(f'{n:>6}  {h}')
EOF
```

Filter for `auth|login|identity|account|sso|cdn|api|upload|ws`. Treat the
output as *candidates*, not confirmed dependencies — bundles also reference
every third-party OAuth target in the app's integrations directory, which are
only reached if a user connects that specific integration. Say plainly which
domains were observed versus inferred.

## NetBird rules that shape the answer

- **Use domain-based routes, not IP ranges.** These apps sit behind Cloudflare
  and equivalents; IPs rotate and an IP route goes stale.
- **The wildcard is a leading-label form only.** `*.example.com` matches
  subdomains. It does **not** match the apex, so list the apex separately
  whenever it was contacted. There is no mid-label glob — see the trap below.
- Enable **masquerade** on the route and confirm the routing peer can egress.
- Domain routes only work if the peer resolves through NetBird's DNS. A
  hardcoded resolver or DNS-over-HTTPS in the client silently bypasses the
  route. Electron apps are Chromium — check that secure DNS is off.
- **Test WebSocket upgrades explicitly.** A path that handles HTTPS fine can
  still break the 101 upgrade. Symptom: UI loads but never streams.

## Traps

**The registrable-domain trap.** Check whether a host is genuinely a subdomain
before reaching for a wildcard. `browser-intake-us5-datadoghq.com` is its own
registrable domain — `*.datadoghq.com` never matches it, and no wildcard can,
because NetBird has no mid-label glob. Pin the exact host or enumerate
variants. Split the hostname on dots and count before assuming.

**Random per-object subdomains.** Artifact and sandbox hosts use a fresh UUID
subdomain per object (`<uuid>.claudeusercontent.com`,
`web-sandbox.oaiusercontent.com`). These *must* be wildcards; an exact host
from a capture is worthless.

**Post-login captures.** If `urls.csv` has no `/auth`, `/session` or `/token`
paths, the capture started authenticated and the login flow is entirely
uncovered. Say so rather than implying the list is complete.

**Failing telemetry is invisible.** A blocked beacon does not degrade the app,
so it looks like nothing is wrong — but confirm it fails *fast*. A blackhole
that resets the connection is kinder than one that drops packets and makes the
client wait for a timeout.

## Verification after rollout

Re-capture a HAR through the tunnel, re-run the script, and check
`server_ip` in `urls.csv` — it should show the exit peer's address. That gives
a clean before/after diff and catches anything the DNS path missed.

## Recorded results

### Claude (desktop + web)

Captured 2026-08-13, three HARs, 820 requests, 10 domains. Traffic is entirely
first-party except Datadog.

```
*.anthropic.com
anthropic.com
*.claude.ai
claude.ai
*.claudeusercontent.com
```

- Desktop-only surface: `/api/bootstrap/…/system_prompts`, `/v1/code/sessions/*`
  (Claude Code sessions + SSE stream), `/api/frame/*`.
- Web-only surface: `/design/anthropic.omelette.api.v1alpha.OmeletteService/*`
  RPCs, `/api/organizations/…/mcp/*`, `/edge-api/*`.
- `browser-intake-us5-datadoghq.com` is Datadog RUM telemetry and is
  **deliberately not routed** — confirmed working, the web capture already
  showed all 55 beacons failing with status 0 while the app functioned
  normally.
- Not exercised by the capture: `*.claude.com` (product domain migration),
  `*.statsig.com`, `*.sentry.io`, login/OAuth, desktop auto-update.

### ChatGPT (web)

Captured 2026-08-13, two Firefox HARs, 1,237 requests, 10 domains observed.
Messier than Claude: two apex domains, a hard WebSocket dependency
(`wss://ws.chatgpt.com`, status 101), an external IdP, and Google-hosted
assets embedded in the product.

```
chatgpt.com
*.chatgpt.com
openai.com
*.openai.com
*.oaistatic.com
*.oaiusercontent.com
*.oaistatsig.com
*.auth0.com
*.blob.core.windows.net
accounts.google.com          # only if Google sign-in
oauth2.googleapis.com        # only if Google sign-in
login.microsoftonline.com    # only if Microsoft sign-in
*.gstatic.com                # cosmetic: citation favicons
www.google.com               # cosmetic: citation favicons
```

- Observed: `chatgpt.com` (1022 req, all `/backend-api/*` and `/cdn/assets/*`),
  `files.openai.com`, `ws.chatgpt.com`, `cdn.openai.com`, `cdn.auth0.com`,
  `www.google.com` + `t0–t3.gstatic.com` (citation favicons, cosmetic only).
- Inferred from bundle strings: `auth.openai.com`, `auth0.openai.com`,
  `auth-cdn.oaistatic.com`, `images.openai.com`, `persistent.oaistatic.com`,
  `web-sandbox.oaiusercontent.com`, `openaiassets.blob.core.windows.net`,
  `api.oaistatsig.com`.
- Session management is NextAuth on `chatgpt.com/api/auth/*`, covered by the
  apex.
- Ignore `login.salesforce.com`, `accounts.zoho.com`, `oauth.pipedrive.com`,
  `cdn.plaid.com` from the string scan — ChatGPT offers no sign-in with these;
  they are OAuth targets for the connectors directory.
- Both captures were fully logged in, so the login flow has **no coverage**.
  Re-capture a logout → login cycle before treating the auth domains as final.
