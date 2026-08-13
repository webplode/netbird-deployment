#!/usr/bin/env bash
# Phase A step 2 — assemble and store the runtime secrets outside Terraform.
#
# Sources, in order of preference:
#   - LIVE files fetched by 00-preflight.sh into .fetched/live/  (authoritative)
#   - prompts for anything unavailable (JumpCloud OAuth client id/secret if the
#     old host had no .env)
# Freshly generated (safe to rotate):
#   - oauth2_cookie_secret_base64 (invalidates dashboard sessions only)
#   - health_token (update any external uptime monitor afterwards)
#
# Never echoes secret values; never writes them outside .fetched/.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cmds aws jq openssl
require_write_profile

LIVE="${FETCH_DIR}/live"
OUT="${FETCH_DIR}/management-secret.local.json"

[[ -f "${LIVE}/management.json" ]] || {
  echo "FATAL: ${LIVE}/management.json missing. Run 00-preflight.sh first." >&2; exit 1; }

log "Assembling management secret from live files"

relay_secret="$(jq -r '.Relay.Secret' "${LIVE}/management.json")"
datastore_key="$(jq -r '.DataStoreEncryptionKey' "${LIVE}/management.json")"
relay_env_secret="$(grep -E '^NB_AUTH_SECRET=' "${LIVE}/relay.env" | cut -d= -f2-)"
if [[ "$relay_secret" != "$relay_env_secret" ]]; then
  echo "FATAL: Relay.Secret in management.json differs from NB_AUTH_SECRET in relay.env — resolve before continuing." >&2
  exit 1
fi
turn_password="$(grep -E '^user=' "${LIVE}/turnserver.conf" | head -1 | cut -d: -f2-)"
[[ -n "$turn_password" ]] || { echo "FATAL: could not parse TURN password." >&2; exit 1; }

if [[ -f "${LIVE}/env" ]]; then
  oauth_id="$(grep -E '^OAUTH2_PROXY_CLIENT_ID=' "${LIVE}/env" | cut -d= -f2-)"
  oauth_secret="$(grep -E '^OAUTH2_PROXY_CLIENT_SECRET=' "${LIVE}/env" | cut -d= -f2-)"
elif [[ -f "${LIVE}/docker-compose.yml" ]] && grep -q 'OAUTH2_PROXY_CLIENT_ID:' "${LIVE}/docker-compose.yml"; then
  # The live compose hardcodes the OAuth credentials inline (verified 2026-08-13).
  oauth_id="$(sed -nE 's/^[[:space:]]*OAUTH2_PROXY_CLIENT_ID:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "${LIVE}/docker-compose.yml" | head -1)"
  oauth_secret="$(sed -nE 's/^[[:space:]]*OAUTH2_PROXY_CLIENT_SECRET:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "${LIVE}/docker-compose.yml" | head -1)"
else
  echo "Old host .env not fetched — enter the JumpCloud OAuth application credentials."
  read -r -p    'JumpCloud OAuth client id: ' oauth_id
  read -r -s -p 'JumpCloud OAuth client secret (hidden): ' oauth_secret; printf '\n'
fi
[[ -n "$oauth_id" && -n "$oauth_secret" ]] || { echo "FATAL: missing OAuth credentials." >&2; exit 1; }

cookie_secret="$(openssl rand -base64 32 | tr -- '+/' '-_' | tr -d '\n=')"
health_token="$(openssl rand -hex 32)"

umask 077
jq -n \
  --arg id "$oauth_id" --arg sec "$oauth_secret" --arg cookie "$cookie_secret" \
  --arg relay "$relay_secret" --arg dsk "$datastore_key" \
  --arg turn "$turn_password" --arg health "$health_token" \
  '{oauth2_client_id: $id, oauth2_client_secret: $sec,
    oauth2_cookie_secret_base64: $cookie, netbird_relay_secret: $relay,
    netbird_datastore_encryption_key: $dsk, turn_password: $turn,
    health_token: $health}' > "$OUT"
unset relay_secret datastore_key relay_env_secret turn_password oauth_id oauth_secret cookie_secret

# Same schema the management bootstrap enforces — fail here, not on the instance.
jq -e '
  (.oauth2_client_id | test("^[A-Za-z0-9._:-]{3,256}$")) and
  (.oauth2_client_secret | length >= 16 and length <= 4096) and
  (.oauth2_cookie_secret_base64 | test("^[A-Za-z0-9_+/=-]+$")) and
  (.netbird_relay_secret | test("^[A-Za-z0-9._~+/=-]{16,4096}$")) and
  (.netbird_datastore_encryption_key | test("^[A-Za-z0-9._~+/=-]{16,4096}$")) and
  (.turn_password | test("^[A-Za-z0-9._~+-]{16,256}$")) and
  (.health_token | test("^[A-Fa-f0-9]{64}$"))
' "$OUT" >/dev/null || { echo "FATAL: assembled secret failed schema validation." >&2; exit 1; }
echo "Secret assembled and schema-validated: $OUT"

log "Writing secrets to Secrets Manager"
mgmt_arn="$(tf_output_json runtime_secret_arns | jq -r .management)"
awsw secretsmanager put-secret-value --secret-id "$mgmt_arn" \
  --secret-string "file://$OUT" >/dev/null
echo "management secret stored: $mgmt_arn"
awsw secretsmanager get-secret-value --secret-id "$mgmt_arn" \
  --query SecretString --output text | jq 'keys'

for peer in peer_1 peer_2; do
  arn="$(tf_output_json runtime_secret_arns | jq -r ".${peer}")"
  keyfile="$(mktemp)"; chmod 600 "$keyfile"
  read -r -s -p "NetBird setup key for ${peer} (one-off, routing-group scoped; hidden): " setup_key
  printf '\n'
  printf '%s' "$setup_key" > "$keyfile"; unset setup_key
  [[ -s "$keyfile" ]] || { echo "FATAL: empty setup key for ${peer}." >&2; rm -f "$keyfile"; exit 1; }
  awsw secretsmanager put-secret-value --secret-id "$arn" \
    --secret-string "file://$keyfile" >/dev/null
  rm -f "$keyfile"
  echo "${peer} setup key stored: $arn"
done

log "Done. health_token was ROTATED — update any external monitor calling /healthz."
log "Next: 04-bootstrap-management.sh"
