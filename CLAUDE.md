# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Dockerized HashiCorp Vault for the UYE project. Single-node, Raft storage, behind a reverse proxy. CI builds and cosign-signs the vault-unseal image; the infra-runner deployer applies it automatically (GitOps — no deploy job in CI).

## Architecture

```
vault/config/vault.hcl         Vault server config (Raft storage, TCP listener)
vault/policies/*.hcl           ACL policy files — applied on every deploy
docker/docker-compose.yml      vault + vault-unseal services
docker/vault-unseal/           Alpine container that polls health and auto-unseals
scripts/bootstrap.sh           One-time server setup: clone, build, start (run via curl | bash)
scripts/init-vault.sh          One-time init: enables KV v2, AppRole, audit, applies policies
scripts/apply-policies.sh      Idempotent policy sync — run manually or called by infra-runner deployer every 60s
scripts/new-app-role.sh        Creates an AppRole + policy file for a new app
.github/workflows/validate.yml PR + push-to-main check: policy syntax via inline Vault dev server (self-hosted runner)
.github/workflows/deploy.yml   Push to main: build vault-unseal with Buildah → push to GHCR → cosign sign by digest
```

### Key design decisions

- **Raft storage** — integrated backend, no Consul dependency
- **TLS disabled on listener** — port bound to `127.0.0.1`; TLS terminated by the reverse proxy
- **Auto-unseal via companion container** — `vault-unseal` polls `/v1/sys/health` every 15s and calls `/v1/sys/unseal` when sealed; key sourced from `VAULT_UNSEAL_KEY` env var
- **AppRole auth** — one role per app; `role_id` is static config, `secret_id` is the runtime credential
- **`vault-net` Docker network** — external named network that app compose files join to reach `http://vault:8200` without host port exposure
- **GitOps deployment via infra-runner deployer** — no deploy job in CI; the deployer polls GHCR every 60s, verifies the cosign signature, restarts `vault-unseal`, and syncs policies autonomously
- **Self-hosted GitHub Actions runner** — provided by infra-runner; runs on the server, connects outbound to GitHub; no SSH keys or WireGuard secrets in GitHub
- **GHCR for vault-unseal image** — built in CI with Buildah + fuse-overlayfs (daemonless OCI builds; `--isolation=chroot` for `RUN` instructions as defence-in-depth). Ubuntu 24.04 sets `apparmor_restrict_unprivileged_userns=1`, which blocks `clone(CLONE_NEWUSER)` without explicit AppArmor permission — the `infra-runner` profile includes `userns,` to allow buildah to create a user-namespaced working container (OCI bundle setup) and for runc isolation of `RUN` steps. Runner container requires `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID]` to unpack Alpine layers. Cosign-signed by digest with keyless OIDC; infra-runner deployer verifies before deploying; local bootstrap uses `build:` for first run. All GitHub Actions `uses:` references are SHA-pinned.
- **Vault CE version for CI validation** — `validate.yml` installs Vault **1.17.6** (the latest Community Edition release; CE capped at 1.17.x — 1.17.7+ are enterprise-only). This matches the production image `hashicorp/vault:1.17`. Do not bump to 2.x without confirming a CE release exists.

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

**None required for deployment.** Deployment is handled entirely by the infra-runner deployer on the server — no SSH keys, WireGuard config, or `VAULT_TOKEN` are stored in GitHub Secrets.

The `VAULT_TOKEN` (ops policy token from `make init`) is stored in infra-runner's `.env` on the server. See infra-runner's vault integration setup.
