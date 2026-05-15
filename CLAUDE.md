# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

Dockerized HashiCorp Vault for the UYE project. Single-node, Raft storage, behind a reverse proxy. CI builds and cosign-signs the vault-unseal image; the infra-runner deployer applies it automatically (GitOps — no deploy job in CI).

## Architecture

```
vault/config/vault.hcl               Vault server config (Raft storage, TCP listener)
vault/policies/*.hcl                 ACL policy files — applied on every deploy
docker/docker-compose.yml            vault + vault-unseal services
docker/vault-unseal/                 Alpine container that polls health and auto-unseals
.infra-runner.plugin                 Plugin descriptor for infra-runner's deployer (image, cert identity, compose coords, hooks)
docker-compose.infra-runner.yml      Compose overlay — mounts workspace + plugin descriptor into infra-runner's deployer container
scripts/bootstrap.sh                 One-time server setup: clone, build, start (run via curl | bash)
scripts/init-vault.sh                One-time init: enables KV v2, AppRole, audit, applies policies
scripts/apply-policies.sh            Idempotent policy sync — called by infra-runner deployer as a post-deploy hook every cycle
scripts/new-app-role.sh              Creates an AppRole + policy file for a new app
.github/workflows/ci.yml             Push to main + PRs: validate policies (GitHub-hosted), then build/push/sign vault-unseal (self-hosted, gated on validate)
```

### Key design decisions

- **Raft storage** — integrated backend, no Consul dependency
- **TLS disabled on listener** — port bound to `127.0.0.1`; TLS terminated by the reverse proxy
- **Auto-unseal via companion container** — `vault-unseal` polls `/v1/sys/health` every 15s and calls `/v1/sys/unseal` when sealed; key sourced from `VAULT_UNSEAL_KEY` env var
- **AppRole auth** — one role per app; `role_id` is static config, `secret_id` is the runtime credential
- **`vault-net` Docker network** — external named network that app compose files join to reach `http://vault:8200` without host port exposure
- **GitOps deployment via infra-runner plugin system** — no deploy job in CI; `.infra-runner.plugin` registers this repo as a plugin; the deployer polls GHCR every 60s, verifies the cosign signature, restarts `vault-unseal`, and runs `scripts/apply-policies.sh` as a post-deploy hook every cycle. `docker-compose.infra-runner.yml` is a Compose overlay that mounts this repo and the plugin descriptor into the deployer container — activate by appending it to `COMPOSE_FILE` in infra-runner's `.env`
- **Self-hosted GitHub Actions runner** — provided by infra-runner; runs on the server, connects outbound to GitHub; no SSH keys or WireGuard secrets in GitHub
- **GHCR for vault-unseal image** — built in CI with Buildah + fuse-overlayfs (daemonless OCI builds; `--isolation=chroot` for `RUN` instructions as defence-in-depth). Ubuntu 24.04 sets `apparmor_restrict_unprivileged_userns=1`, which blocks `clone(CLONE_NEWUSER)` without explicit AppArmor permission — the `infra-runner` profile includes `userns,` and `ptrace (read, trace, readby, tracedby) peer=infra-runner,` to allow buildah to create user-namespaced build containers and write uid_map/gid_map across the user-namespace boundary. Runner container requires `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, SYS_PTRACE, SYS_ADMIN]`: the last two are required by the kernel's user-namespace setup path (`proc_setgroups_open` calls `ptrace_may_access`; full-range uid_map writes require `CAP_SYS_ADMIN`). Cosign-signed by digest with keyless OIDC; infra-runner deployer verifies before deploying; local bootstrap uses `build:` for first run. All GitHub Actions `uses:` references are SHA-pinned.
- **Vault CLI in deploy runner** — Vault is baked into the self-hosted runner image (installed via HashiCorp APT during image build on GitHub-hosted runners). Runtime install from either `releases.hashicorp.com` or `apt.releases.hashicorp.com` returns HTTP 404 from the runner server's IP — CloudFront WAF geo-restriction confirmed by the `x-amzn-waf-reason: geo` response header. The validate job runs on `ubuntu-latest` (GitHub-hosted) and installs Vault via APT at runtime, which works because GitHub-hosted runners are not geo-blocked. Vault CE is available through 2.x; an older "CE capped at 1.17.x" claim was incorrect.

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
