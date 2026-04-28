# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Dockerized HashiCorp Vault for the UYE project. Single-node, Raft storage, behind a reverse proxy. GitHub Actions deploys to a bare-metal server via SSH.

## Architecture

```
vault/config/vault.hcl         Vault server config (Raft storage, TCP listener)
vault/policies/*.hcl           ACL policy files — applied on every deploy
docker/docker-compose.yml      vault + vault-unseal services
docker/vault-unseal/           Alpine container that polls health and auto-unseals
scripts/bootstrap.sh           One-time server setup: clone, build, start (run via curl | bash)
scripts/init-vault.sh          One-time init: enables KV v2, AppRole, audit, applies policies
scripts/apply-policies.sh      Idempotent policy sync (runs in CI/CD on every deploy)
scripts/new-app-role.sh        Creates an AppRole + policy file for a new app
.github/workflows/validate.yml PR check: policy syntax via live dev-mode Vault
.github/workflows/deploy.yml   Push to main: build image → push to GHCR → self-hosted runner deploys
```

### Key design decisions

- **Raft storage** — integrated backend, no Consul dependency
- **TLS disabled on listener** — port bound to `127.0.0.1`; TLS terminated by the reverse proxy
- **Auto-unseal via companion container** — `vault-unseal` polls `/v1/sys/health` every 15s and calls `/v1/sys/unseal` when sealed; key sourced from `VAULT_UNSEAL_KEY` env var
- **AppRole auth** — one role per app; `role_id` is static config, `secret_id` is the runtime credential
- **`vault-net` Docker network** — external named network that app compose files join to reach `http://vault:8200` without host port exposure
- **Self-hosted GitHub Actions runner** — runs on the server, connects outbound to GitHub; no SSH keys stored in GitHub Secrets
- **GHCR for vault-unseal image** — built in CI, pulled by the runner on deploy; local bootstrap uses `build:` for first run

### Adding a new app to Vault

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<ops-token>
./scripts/new-app-role.sh my-app            # read-only
./scripts/new-app-role.sh my-app --readwrite
```

This creates `vault/policies/my-app.hcl` and prints `VAULT_ROLE_ID` / `VAULT_SECRET_ID`.

App compose files connect to Vault by joining the external network:

```yaml
networks:
  vault-net:
    external: true
```

Then reach Vault at `http://vault:8200`.

## Common Commands

```bash
make up              # start vault + vault-unseal
make down            # stop services
make build           # rebuild images (use after editing vault-unseal/)
make logs            # tail vault logs
make status          # vault status on localhost:8200
make init            # first-time initialization (run once)
make apply-policies  # sync all vault/policies/*.hcl
```

## First-time setup and operational procedures

See `README.md` for full step-by-step instructions covering: server setup, secret management, connecting apps, AppRole rotation, token management, and troubleshooting.

## GitHub Actions Secrets Required

`VAULT_TOKEN` only (ops policy token from `make init` output). SSH secrets are not needed — deployment uses a self-hosted runner on the server.
