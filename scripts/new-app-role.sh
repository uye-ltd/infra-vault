#!/usr/bin/env bash
# Creates an AppRole and policy for a new application.
# Usage: ./scripts/new-app-role.sh <app-name> [--readwrite]
#
# By default, creates a read-only policy. Pass --readwrite to allow writes.
set -euo pipefail

APP_NAME="${1:-}"
MODE="${2:-}"

[ -z "$APP_NAME" ] && { echo "Usage: $0 <app-name> [--readwrite]"; exit 1; }

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR
[ -z "${VAULT_TOKEN:-}" ] && { echo "VAULT_TOKEN is required"; exit 1; }
export VAULT_TOKEN

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY_FILE="$REPO_ROOT/vault/policies/${APP_NAME}.hcl"

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

if [ -f "$POLICY_FILE" ]; then
  echo "Policy file already exists: $POLICY_FILE — using existing file"
else
  if [ "$MODE" = "--readwrite" ]; then
    cat > "$POLICY_FILE" <<EOF
path "secret/data/${APP_NAME}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/${APP_NAME}/*" {
  capabilities = ["read", "list", "delete"]
}
EOF
  else
    cat > "$POLICY_FILE" <<EOF
path "secret/data/${APP_NAME}/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/${APP_NAME}/*" {
  capabilities = ["read", "list"]
}
EOF
  fi
  echo "Created policy: $POLICY_FILE"
fi

vault_cmd policy write "$APP_NAME" - < "$POLICY_FILE"

vault_cmd write "auth/approle/role/${APP_NAME}" \
  token_policies="$APP_NAME" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

ROLE_ID=$(vault_cmd read -field=role_id "auth/approle/role/${APP_NAME}/role-id")
SECRET_ID=$(vault_cmd write -f -field=secret_id "auth/approle/role/${APP_NAME}/secret-id")

echo ""
echo "AppRole created for: $APP_NAME"
echo "  VAULT_ROLE_ID   = $ROLE_ID"
echo "  VAULT_SECRET_ID = $SECRET_ID"
echo ""
echo "The app authenticates with:"
echo "  vault write auth/approle/login role_id=\$VAULT_ROLE_ID secret_id=\$VAULT_SECRET_ID"
