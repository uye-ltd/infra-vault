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

for cmd in docker git make curl; do
  command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required but not installed."; exit 1; }
done

# Check Docker socket access before doing anything else
if ! docker info >/dev/null 2>&1; then
  echo ""
  echo "Error: cannot connect to Docker. Your user needs to be in the 'docker' group."
  echo ""
  echo "  Fix:"
  echo "    sudo usermod -aG docker \$USER"
  echo "    newgrp docker          # apply without logging out"
  echo ""
  echo "Then re-run this script."
  exit 1
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

# Create .env if not already present
if [ ! -f .env ]; then
  cp .env.example .env
  step "Created .env from template"
fi

# Start containers, building vault-unseal locally on first run
step "Starting containers (building vault-unseal locally for first run)..."
docker compose -f docker/docker-compose.yml up -d --build

echo ""
box "================================================================"
box "  Vault is starting. Complete the following steps:"
box "================================================================"
echo ""
echo "  1. Initialize Vault and get your keys:"
echo "     cd $INSTALL_DIR && make init"
echo ""
echo "  2. Fill in the unseal key in .env:"
echo "     nano $INSTALL_DIR/.env"
echo "     → VAULT_UNSEAL_KEY=<key printed by make init>"
echo ""
echo "  3. Restart so vault-unseal picks up the key:"
echo "     make up"
echo ""
echo "  4. Install the GitHub Actions runner on this server:"
echo "     Go to: https://github.com/uye-ltd/infra-vault/settings/actions/runners"
echo "     Click 'New self-hosted runner' and follow the Linux instructions."
echo "     When asked for the runner directory, use: $INSTALL_DIR/runner"
echo ""
echo "  5. Add one GitHub Secret:"
echo "     VAULT_TOKEN = <CI/CD token printed by make init>"
echo ""
echo "  After that, every push to main deploys automatically — no SSH needed."
echo ""
