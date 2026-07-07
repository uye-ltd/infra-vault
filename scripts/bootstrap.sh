#!/usr/bin/env bash
# First-time server setup. Run once on a fresh machine.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uye-ltd/infra-vault/main/scripts/bootstrap.sh | bash
#   or: bash scripts/bootstrap.sh
set -euo pipefail

REPO="https://github.com/uye-ltd/infra-vault.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/infra-vault}"

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "${GREEN}==>${NC} $*"; }
box()  { echo -e "${BOLD}$*${NC}"; }

for cmd in git make curl sudo; do
  command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required but not installed."; exit 1; }
done

# Docker socket check — common failure point on first run
if ! docker info >/dev/null 2>&1; then
  echo ""
  echo "Error: cannot connect to Docker."
  echo ""
  echo "  Fix:"
  echo "    sudo usermod -aG docker \$USER"
  echo "    exit   # disconnect SSH completely, then reconnect"
  echo ""
  echo "  A new SSH session is required — group changes don't apply to existing sessions."
  echo ""
  exit 1
fi

# Docker Compose v2 check (plugin, not standalone docker-compose)
if ! docker compose version >/dev/null 2>&1; then
  echo "Error: Docker Compose v2 plugin not found."
  echo "Install Docker Engine via: https://docs.docker.com/engine/install/ubuntu/"
  exit 1
fi

# Install jq if missing — required for vault init output parsing
if ! command -v jq &>/dev/null; then
  step "Installing jq..."
  sudo apt-get update -qq && sudo apt-get install -y -qq jq
fi

# Clone or update the repository
if [ -d "$INSTALL_DIR/.git" ]; then
  step "Repository already exists — pulling latest..."
  git -C "$INSTALL_DIR" pull origin main
else
  step "Cloning repository to $INSTALL_DIR..."
  git clone "$REPO" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

if [ ! -f docker/.env ]; then
  cp docker/.env.example docker/.env
  step "Created docker/.env from template"
fi

step "Starting containers (building vault-unseal locally for first run)..."
docker compose -f docker/docker-compose.yml up -d --build

echo ""
box "================================================================"
box "  Setup complete. Next steps:"
box "================================================================"
echo ""
echo "  1. Initialize Vault:"
echo "     cd $INSTALL_DIR && make init"
echo ""
echo "  2. Save the unseal key to docker/.env:"
echo "     nano $INSTALL_DIR/docker/.env"
echo "     → VAULT_UNSEAL_KEY=<key printed by make init>"
echo ""
echo "  3. Restart to activate auto-unseal:"
echo "     make up"
echo ""
echo "  4. Install the GitHub Actions runner:"
echo "     Go to: https://github.com/uye-ltd/infra-vault/settings/actions/runners"
echo "     Click 'New self-hosted runner', follow the Linux instructions."
echo "     Runner directory: $INSTALL_DIR/runner"
echo ""
echo "  5. Add one GitHub Secret (Settings → Secrets → Actions):"
echo "     VAULT_TOKEN = <CI/CD token printed by make init>"
echo ""
echo "  After that, every push to main deploys automatically — no SSH needed."
echo ""
