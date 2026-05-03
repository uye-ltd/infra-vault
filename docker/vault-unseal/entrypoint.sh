#!/bin/sh
set -eu

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
INTERVAL="${INTERVAL:-15}"

log() { echo "[vault-unseal] $*"; }

wait_for_vault() {
  log "waiting for vault to respond..."
  # Health endpoint returns a non-connection-error code even when sealed/uninitialized
  until curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health" 2>/dev/null \
      | grep -qE "^(200|429|472|473|501|503)$"; do
    sleep 3
  done
  log "vault is up"
}

is_initialized() {
  result=$(curl -sf "${VAULT_ADDR}/v1/sys/init" 2>/dev/null) || return 1
  echo "$result" | jq -e '.initialized == true' >/dev/null 2>&1
}

is_sealed() {
  result=$(curl -sf "${VAULT_ADDR}/v1/sys/health" 2>/dev/null) || return 0 # assume sealed on error
  echo "$result" | jq -e '.sealed == true' >/dev/null 2>&1
}

do_unseal() {
  log "vault is sealed, sending unseal key..."
  result=$(curl -s -X PUT "${VAULT_ADDR}/v1/sys/unseal" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"${VAULT_UNSEAL_KEY}\"}" 2>/dev/null) || { log "unseal request failed (network error)"; return; }

  if echo "$result" | jq -e '.sealed == false' >/dev/null 2>&1; then
    log "vault unsealed successfully"
  else
    log "unseal result: $(echo "$result" | jq -c '{sealed,progress,errors}' 2>/dev/null || echo "$result")"
  fi
}

wait_for_vault

while true; do
  if is_initialized; then
    if is_sealed; then
      do_unseal
    fi
  else
    log "vault is not yet initialized — run scripts/init-vault.sh"
  fi
  sleep "$INTERVAL"
done
