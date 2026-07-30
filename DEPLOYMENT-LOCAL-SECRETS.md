# Local Deployment Secrets

The checked-in files are templates. Runtime credentials must stay on the host
and must never be committed.

From the repository root, create the local files before starting Compose:

```sh
cp .env.example .env
cp management.json.example management.json
cp relay.env.example relay.env
cp turnserver.conf.example turnserver.conf
```

Fill `.env` with the OAuth2-Proxy values, and replace the placeholders in the
management, relay, and TURN files with values from the secret store. Restrict
the files to the deployment administrator (`chmod 600 .env management.json
relay.env turnserver.conf`).

The same process applies to the files under `netbird-ec2-install-bundle/`.
The `.gitignore` rules intentionally exclude these runtime files, Caddy ACME
state, backups, HAR captures, and generated test artifacts.
