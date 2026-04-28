#!/usr/bin/env bash
# Run once on a fresh Vault installation. Idempotent: exits early if already initialized.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export VAULT_ADDR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
box()  { echo -e "${BOLD}$*${NC}"; }

for cmd in vault jq curl; do
  command -v "$cmd" &>/dev/null || err "Required command not found: $cmd"
done

log "Checking Vault at $VAULT_ADDR..."
curl -sf "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 || err "Vault is not reachable. Is it running?"

INIT_STATUS=$(vault status -format=json 2>/dev/null || true)
if echo "$INIT_STATUS" | jq -e '.initialized == true' >/dev/null 2>&1; then
  warn "Vault is already initialized. Use scripts/apply-policies.sh to sync policies."
  exit 0
fi

log "Initializing Vault with 1 key share..."
INIT_OUTPUT=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)
UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

echo ""
box "================================================================"
box "  SAVE THESE VALUES — DISPLAYED ONLY ONCE"
box "================================================================"
box "  Unseal Key : $UNSEAL_KEY"
box "  Root Token : $ROOT_TOKEN"
box "================================================================"
echo ""
echo "  Next steps:"
echo "  1. Add to GitHub Secrets:  VAULT_UNSEAL_KEY = $UNSEAL_KEY"
echo "  2. Add to server .env file: VAULT_UNSEAL_KEY=$UNSEAL_KEY"
echo "  3. Store root token in a password manager, then revoke it after setup"
echo ""

log "Unsealing Vault..."
vault operator unseal "$UNSEAL_KEY"

export VAULT_TOKEN="$ROOT_TOKEN"

log "Enabling KV v2 secrets engine at secret/..."
vault secrets enable -path=secret kv-v2

log "Enabling AppRole auth method..."
vault auth enable approle

log "Enabling audit log..."
vault audit enable file file_path=/vault/logs/audit.log

log "Applying policies from vault/policies/..."
for policy_file in "$REPO_ROOT/vault/policies/"*.hcl; do
  policy_name=$(basename "$policy_file" .hcl)
  vault policy write "$policy_name" "$policy_file"
  log "  Applied: $policy_name"
done

log "Creating ops token (non-expiring, for CI/CD)..."
OPS_TOKEN=$(vault token create -policy=ops -display-name=ci-ops -format=json | jq -r '.auth.client_token')
echo ""
box "  CI/CD Token (ops policy): $OPS_TOKEN"
echo "  Add to GitHub Secrets as: VAULT_TOKEN"
echo ""

log "Vault is ready."
log "Create your first app role with: ./scripts/new-app-role.sh <app-name>"
