#!/bin/bash
# Post-deploy hook called by infra-runner's deployer each poll cycle.
# Idempotently syncs all vault/policies/*.hcl files into Vault.
# Failure exits non-zero (deployer treats this as a non-blocking warning).
#
# Required env: VAULT_TOKEN, VAULT_COMPOSE_DIR
# Optional env: VAULT_ADDR (default: http://vault:8200), VAULT_NET (default: vault-net)
set -euo pipefail

: "${VAULT_TOKEN:?VAULT_TOKEN is required}"
: "${VAULT_COMPOSE_DIR:?VAULT_COMPOSE_DIR is required}"
VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_NET="${VAULT_NET:-vault-net}"

docker run --rm \
  --network "${VAULT_NET}" \
  -e VAULT_ADDR="${VAULT_ADDR}" \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  -v "${VAULT_COMPOSE_DIR}/vault/policies:/policies:ro" \
  hashicorp/vault:1.17 \
  sh -c 'set -e; for f in /policies/*.hcl; do
    name=$(basename "$f" .hcl); vault policy write "$name" "$f"; echo "Applied: $name"
  done' \
  || { echo "Vault policy sync failed — Vault may be sealed or unreachable" >&2; exit 1; }
