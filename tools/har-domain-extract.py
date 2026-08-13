#!/usr/bin/env python3
"""Extract every URL and domain contacted in a set of HAR captures.

Usage:
    python3 extract_endpoints.py [har-dir-or-files ...]

Outputs, per client (Claude Desktop / Claude Web / other):
  - domains.csv  : domain, hits, methods, statuses, files it appeared in
  - urls.csv     : full URL (query stripped into its own column), method, status,
                   content-type, bytes, initiator/referer
and prints a summary to stdout.
"""

import csv
import json
import os
import sys
from collections import defaultdict
from urllib.parse import urlsplit

OUT_DIR = os.environ.get("OUT_DIR", "har-report")


def client_of(entry):
    """Classify a request as coming from the desktop app or the browser."""
    ua = ""
    for h in entry.get("request", {}).get("headers", []):
        if h.get("name", "").lower() == "user-agent":
            ua = h.get("value", "")
            break
    if "Electron" in ua:
        return "desktop-app"
    if ua:
        return "browser"
    return "unknown"


def header(entry, side, name):
    for h in entry.get(side, {}).get("headers", []):
        if h.get("name", "").lower() == name:
            return h.get("value", "")
    return ""


def registrable(host):
    """Rough eTLD+1 so subdomains group under one parent."""
    parts = host.split(".")
    if len(parts) <= 2:
        return host
    two = ".".join(parts[-2:])
    # handle the common multi-part public suffixes seen in web traffic
    if two in {"co.uk", "com.au", "co.jp", "com.br", "co.in", "com.mx", "net.au"}:
        return ".".join(parts[-3:])
    return two


def har_files(argv):
    targets = argv or ["."]
    files = []
    for t in targets:
        if os.path.isdir(t):
            files += [os.path.join(t, f) for f in sorted(os.listdir(t)) if f.endswith(".har")]
        elif t.endswith(".har"):
            files.append(t)
    return files


def main():
    files = har_files(sys.argv[1:])
    if not files:
        sys.exit("no .har files found")

    os.makedirs(OUT_DIR, exist_ok=True)

    rows = []          # one dict per request
    domains = defaultdict(lambda: defaultdict(lambda: {
        "hits": 0, "methods": set(), "statuses": set(), "files": set(),
        "paths": set(), "scheme": set(), "bytes": 0,
    }))

    for path in files:
        name = os.path.basename(path)
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            log = json.load(fh)["log"]

        for e in log.get("entries", []):
            req = e.get("request", {})
            res = e.get("response", {})
            url = req.get("url", "")
            if not url:
                continue
            u = urlsplit(url)
            host = u.hostname or ""
            if not host:
                continue

            cl = client_of(e)
            size = res.get("bodySize", 0) or 0
            if size < 0:
                size = res.get("content", {}).get("size", 0) or 0

            d = domains[cl][host]
            d["hits"] += 1
            d["methods"].add(req.get("method", ""))
            d["statuses"].add(str(res.get("status", "")))
            d["files"].add(name)
            d["scheme"].add(u.scheme)
            d["bytes"] += size
            if u.path:
                d["paths"].add(u.path)

            rows.append({
                "client": cl,
                "har_file": name,
                "started": e.get("startedDateTime", ""),
                "method": req.get("method", ""),
                "scheme": u.scheme,
                "domain": host,
                "registrable_domain": registrable(host),
                "path": u.path,
                "query": u.query,
                "url_no_query": f"{u.scheme}://{u.netloc}{u.path}",
                "url": url,
                "status": res.get("status", ""),
                "content_type": res.get("content", {}).get("mimeType", ""),
                "resource_type": e.get("_resourceType", ""),
                "bytes": size,
                "time_ms": round(e.get("time", 0) or 0, 1),
                "referer": header(e, "request", "referer"),
                "origin": header(e, "request", "origin"),
                "server_ip": e.get("serverIPAddress", ""),
            })

    # ---- urls.csv -------------------------------------------------------
    url_csv = os.path.join(OUT_DIR, "urls.csv")
    with open(url_csv, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(sorted(rows, key=lambda r: (r["client"], r["domain"], r["path"])))

    # ---- domains.csv ----------------------------------------------------
    dom_csv = os.path.join(OUT_DIR, "domains.csv")
    with open(dom_csv, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["client", "domain", "registrable_domain", "hits", "unique_paths",
                    "schemes", "methods", "statuses", "total_bytes", "har_files"])
        for cl in sorted(domains):
            for host, d in sorted(domains[cl].items(), key=lambda kv: -kv[1]["hits"]):
                w.writerow([
                    cl, host, registrable(host), d["hits"], len(d["paths"]),
                    "|".join(sorted(d["scheme"])),
                    "|".join(sorted(m for m in d["methods"] if m)),
                    "|".join(sorted(s for s in d["statuses"] if s)),
                    d["bytes"], "|".join(sorted(d["files"])),
                ])

    # ---- unique domain list (plain text, for allowlists) ----------------
    txt = os.path.join(OUT_DIR, "domains.txt")
    all_hosts = sorted({h for cl in domains for h in domains[cl]})
    with open(txt, "w", encoding="utf-8") as fh:
        fh.write("\n".join(all_hosts) + "\n")

    # ---- summary --------------------------------------------------------
    print(f"parsed {len(files)} HAR file(s), {len(rows)} requests\n")
    for cl in sorted(domains):
        hosts = domains[cl]
        total = sum(d["hits"] for d in hosts.values())
        print(f"== {cl} — {len(hosts)} domains, {total} requests ==")
        by_reg = defaultdict(int)
        for host, d in hosts.items():
            by_reg[registrable(host)] += d["hits"]
        for reg, n in sorted(by_reg.items(), key=lambda kv: -kv[1]):
            subs = sorted(h for h in hosts if registrable(h) == reg)
            print(f"  {reg:<32} {n:>5} req   [{', '.join(subs)}]")
        print()

    print(f"wrote {url_csv}")
    print(f"wrote {dom_csv}")
    print(f"wrote {txt}  ({len(all_hosts)} unique domains)")


if __name__ == "__main__":
    main()
