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

# jq is required for parsing init output; install via bootstrap.sh or: sudo apt install jq
command -v jq &>/dev/null || err "jq is required. Install with: sudo apt install jq"
command -v curl &>/dev/null || err "curl is required."

# Use local vault CLI if available, otherwise run commands inside the vault container
if command -v vault &>/dev/null; then
  vault_cmd() { vault "$@"; }
else
  command -v docker &>/dev/null || err "Neither 'vault' CLI nor 'docker' found."
  log "vault CLI not found — using 'docker exec vault vault'"
  # -i keeps stdin open so 'vault policy write name -' can read from a pipe
  vault_cmd() {
    docker exec -i \
      -e VAULT_ADDR="${VAULT_ADDR}" \
      -e VAULT_TOKEN="${VAULT_TOKEN:-}" \
      vault vault "$@"
  }
fi

log "Checking Vault at $VAULT_ADDR..."
curl -sf "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 || err "Vault is not reachable. Is 'make up' running?"

INIT_STATUS=$(vault_cmd status -format=json 2>/dev/null || true)
if echo "$INIT_STATUS" | jq -e '.initialized == true' >/dev/null 2>&1; then
  warn "Vault is already initialized. Use scripts/apply-policies.sh to sync policies."
  exit 0
fi

log "Initializing Vault with 1 key share..."
INIT_OUTPUT=$(vault_cmd operator init -key-shares=1 -key-threshold=1 -format=json)
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
echo "  1. Add to server .env: VAULT_UNSEAL_KEY=$UNSEAL_KEY"
echo "  2. Store root token in a password manager, then revoke it after setup"
echo ""

log "Unsealing Vault..."
vault_cmd operator unseal "$UNSEAL_KEY"

export VAULT_TOKEN="$ROOT_TOKEN"

log "Enabling KV v2 secrets engine at secret/..."
vault_cmd secrets enable -path=secret kv-v2

log "Enabling AppRole auth method..."
vault_cmd auth enable approle

log "Enabling audit log..."
vault_cmd audit enable file file_path=/vault/logs/audit.log

log "Applying policies from vault/policies/..."
for policy_file in "$REPO_ROOT/vault/policies/"*.hcl; do
  policy_name=$(basename "$policy_file" .hcl)
  vault_cmd policy write "$policy_name" - < "$policy_file"
  log "  Applied: $policy_name"
done

log "Creating ops token (non-expiring, for CI/CD)..."
OPS_TOKEN=$(vault_cmd token create -policy=ops -display-name=ci-ops -format=json | jq -r '.auth.client_token')

echo ""
box "================================================================"
box "  CI/CD Token (ops policy): $OPS_TOKEN"
box "  Add to GitHub Secrets as: VAULT_TOKEN"
box "================================================================"
echo ""
log "Vault is ready."
log "Create your first app role with: ./scripts/new-app-role.sh <app-name>"
