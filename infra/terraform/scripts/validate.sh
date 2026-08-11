#!/usr/bin/env bash
set -Eeuo pipefail

for required_tool in terraform rg; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "FATAL: required validation tool not found: $required_tool" >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd "$script_dir/.." && pwd)"
cd "$terraform_dir"

terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
terraform test

if rg -n '(^|[[:space:]])image:[[:space:]]+[^#[:space:]]*:latest([@[:space:]]|$)' templates/management; then
  echo "FATAL: mutable latest image found in management template" >&2
  exit 1
fi

if rg -n 'resource[[:space:]]+"aws_secretsmanager_secret_version"' --glob '*.tf' .; then
  echo "FATAL: secret values must not be managed in Terraform state" >&2
  exit 1
fi

if ! rg -q 'instance_type[[:space:]]*=[[:space:]]*"t4g.small"' locals.tf; then
  echo "FATAL: all nodes must remain fixed to t4g.small" >&2
  exit 1
fi

if ! rg -Fq 'redir https://${domain}{uri} 308' templates/management/Caddyfile.tftpl; then
  echo "FATAL: management HTTP must use a fixed-domain 308 redirect" >&2
  exit 1
fi

if ! rg -q 'rpmkeys --checksig' templates/peer-bootstrap.sh.tftpl || \
  ! rg -q 'tsflags=noscripts' templates/peer-bootstrap.sh.tftpl; then
  echo "FATAL: peer RPM signature verification and pre-profile auto-start suppression are required" >&2
  exit 1
fi

echo "Terraform and local security invariants passed."
