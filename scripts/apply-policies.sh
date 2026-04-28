#!/usr/bin/env bash
# Idempotently applies all policy files in vault/policies/ to Vault.
# Safe to run on every deployment — existing policies are updated, new ones are created.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
POLICIES_DIR="$(cd "$(dirname "$0")/../vault/policies" && pwd)"
export VAULT_ADDR

[ -z "${VAULT_TOKEN:-}" ] && { echo "VAULT_TOKEN is required"; exit 1; }
export VAULT_TOKEN

if command -v vault &>/dev/null; then
  vault_cmd() { vault "$@"; }
else
  vault_cmd() {
    docker exec -i \
      -e VAULT_ADDR="${VAULT_ADDR}" \
      -e VAULT_TOKEN="${VAULT_TOKEN}" \
      vault vault "$@"
  }
fi

echo "Applying policies from $POLICIES_DIR..."
for policy_file in "$POLICIES_DIR"/*.hcl; do
  policy_name=$(basename "$policy_file" .hcl)
  vault_cmd policy write "$policy_name" - < "$policy_file"
  echo "  Applied: $policy_name"
done
echo "Done."
