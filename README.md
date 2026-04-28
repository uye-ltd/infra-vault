# infra-vault

HashiCorp Vault secrets management for the UYE infrastructure. Runs as a Docker container on a bare-metal server, auto-unseals on restart, and syncs configuration changes via GitHub Actions.

---

## Table of Contents

- [What is this?](#what-is-this)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [First-time server setup](#first-time-server-setup)
- [Connecting the CI/CD pipeline](#connecting-the-cicd-pipeline)
- [Managing secrets](#managing-secrets)
- [Giving an app access to secrets](#giving-an-app-access-to-secrets)
  - [Dockerized apps](#dockerized-apps)
  - [Apps installed on the host](#apps-installed-on-the-host)
- [Managing AppRoles](#managing-approles)
- [Managing tokens](#managing-tokens)
- [Managing policies](#managing-policies)
- [Vault UI](#vault-ui)
- [Rotating the unseal key](#rotating-the-unseal-key)
- [Upgrading Vault](#upgrading-vault)
- [Troubleshooting](#troubleshooting)

---

## What is this?

[HashiCorp Vault](https://www.vaultproject.io/) is a secrets manager: instead of scattering database passwords, API keys, and certificates across `.env` files and Docker Compose configs, you store them in one place, control who can read what, and get an audit log of every access.

This repo contains:
- The Vault server configuration (Raft storage, no external database needed)
- A companion container that automatically unseals Vault when it restarts
- ACL policies that control per-app access
- Scripts for common operations
- A GitHub Actions pipeline that validates config on PRs and deploys on push to `main`

---

## How it works

```
┌─────────────────────────────────────────────────────┐
│  Server                                             │
│                                                     │
│  ┌──────────────┐   ┌──────────────────┐           │
│  │    vault     │◄──│  vault-unseal    │           │
│  │  :8200       │   │  (auto-unsealer) │           │
│  └──────┬───────┘   └──────────────────┘           │
│         │ vault-net (Docker bridge)                 │
│  ┌──────┴───────────────────────────────┐          │
│  │   app-1   app-2   app-3  (Docker)    │          │
│  └──────────────────────────────────────┘          │
│                                                     │
│  host-app (Python/Go on bare metal)                 │
│  → http://127.0.0.1:8200                           │
│                                                     │
│  ┌──────────────────────────┐                      │
│  │  GitHub Actions runner   │◄── GitHub (outbound) │
│  │  (runs deploy workflows) │                      │
│  └──────────────────────────┘                      │
└─────────────────────────────────────────────────────┘
         ▲
    reverse proxy (nginx/traefik)
    handles TLS
```

**Vault** listens on `127.0.0.1:8200` — not exposed to the internet. Your reverse proxy provides TLS.

**vault-unseal** is a tiny Alpine container that runs alongside Vault. Every 15 seconds it checks whether Vault is sealed; if it is, it sends the unseal key automatically. This handles server reboots without manual intervention.

**vault-net** is a named Docker bridge network. Any Docker Compose project that joins it can reach Vault at `http://vault:8200` without any host-level port exposure.

**AppRole** is the auth method used by all apps. Each app has a `role_id` (public, like a username) and a `secret_id` (private, like a password). The app exchanges these for a short-lived token, then uses that token to read its secrets.

**GitHub Actions self-hosted runner** runs directly on the server. It connects *outbound* to GitHub to receive jobs — no SSH port needs to be open, and no SSH keys are stored in GitHub. When you push to `main`, the runner pulls the latest code and images and restarts services locally.

---

## Prerequisites

### On your local machine (for running scripts)

- `vault` CLI — [install guide](https://developer.hashicorp.com/vault/install)
- `jq` — `brew install jq` / `apt install jq`
- `curl`, `make` (usually pre-installed)

### On the server

- Docker Engine + Docker Compose plugin
- `git`
- `make`

---

## First-time server setup

### Prerequisites: Docker group

Your user must be in the `docker` group. If `docker ps` shows a permission error:

```bash
sudo usermod -aG docker $USER
exit            # disconnect SSH completely
# reconnect, then verify:
groups          # 'docker' must appear in the list
```

> Group changes only apply to new login sessions — `newgrp` is not sufficient.

---

### Step 1 — Get the repo onto the server

**Option A — fresh server (recommended):** run the bootstrap script. It clones the repo, installs `jq`, and starts the containers in one step:

```bash
curl -fsSL https://raw.githubusercontent.com/uye-ltd/infra-vault/main/scripts/bootstrap.sh | bash
```

Skip to **Step 2** when it finishes.

**Option B — repo already cloned:** start the containers manually:

```bash
cd ~/infra-vault
git pull origin main          # make sure you have the latest
make up                       # builds vault-unseal image and starts both containers
```

Verify the containers are running:

```bash
docker ps
# Should show: vault   Up X seconds
#              vault-unseal   Up X seconds
```

---

### Step 2 — Initialize Vault

```bash
cd ~/infra-vault
make init
```

This runs `scripts/init-vault.sh`, which:
- Generates the unseal key and root token
- Unseals Vault
- Enables KV v2 secrets at `secret/`
- Enables AppRole authentication
- Enables the audit log
- Applies all policies from `vault/policies/`
- Creates an ops token for the CI/CD pipeline

**The output will look like this — save it immediately before doing anything else:**

```
================================================================
  SAVE THESE VALUES — DISPLAYED ONLY ONCE
================================================================
  Unseal Key : hvs.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  Root Token : hvs.YYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY
================================================================

  CI/CD Token (ops policy): hvs.ZZZZZZZZZZZZZZZZZZZZZZZZZZZZ
```

| Value | Where to store it |
|---|---|
| Unseal Key | Password manager + server `.env` (step 3) |
| Root Token | Password manager only — revoke after setup (step 5) |
| CI/CD Token | GitHub Secret `VAULT_TOKEN` (step 6) |

---

### Step 3 — Save the unseal key to .env

```bash
nano ~/infra-vault/.env
# Set: VAULT_UNSEAL_KEY=hvs.XXXXXXXX...
```

---

### Step 4 — Restart so vault-unseal picks up the key

```bash
make up
docker logs vault-unseal
# Should show: [vault-unseal] vault unsealed successfully
```

---

### Step 5 — Revoke the root token

The root token bypasses all policies. Revoke it after setup — use the ops token for everything else:

```bash
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 \
  vault vault token revoke hvs.YYYYYYYY...
```

---

### 6. Install the GitHub Actions runner

This replaces SSH-based deployment. The runner connects outbound to GitHub and runs workflow jobs directly on the server — no inbound ports, no SSH keys in GitHub.

Go to your repository: **Settings → Actions → Runners → New self-hosted runner**

Select **Linux** and follow the instructions GitHub shows. When prompted for the working directory, use `~/infra-vault/runner`.

Start the runner as a system service so it survives reboots:

```bash
cd ~/infra-vault/runner
sudo ./svc.sh install
sudo ./svc.sh start
```

Verify it appears as **Idle** in GitHub under Settings → Actions → Runners.

---

## Connecting the CI/CD pipeline

Add **one secret** to your GitHub repository under **Settings → Secrets and variables → Actions**:

| Secret name | Value |
|---|---|
| `VAULT_TOKEN` | The ops token printed by `make init` |

That's it. No SSH keys, no host addresses. The self-hosted runner handles everything locally.

**After setup:**
- Pull requests that touch `vault/` or `docker/` automatically validate policy syntax
- Any push to `main`:
  1. Builds the `vault-unseal` image and pushes it to GitHub Container Registry (GHCR)
  2. The self-hosted runner on your server pulls the new image, restarts containers, and applies policies

> **First push note:** GHCR packages are private by default. After the first successful build, go to your GitHub profile → **Packages → vault-unseal → Package settings** and set visibility to **Public** (or keep it private and the runner uses its `GITHUB_TOKEN` automatically via the deploy workflow).

---

## Managing secrets

All secrets live in the KV v2 engine at the `secret/` path. Think of it like a filesystem where the path is `secret/<app-name>/<key-group>`.

Set the environment variables once for your session (use the ops token or root token):

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=hvs.ZZZZZZZZ...   # ops token
```

### Write secrets

```bash
# Single value
vault kv put secret/my-app/database password="hunter2"

# Multiple values at once
vault kv put secret/my-app/database \
  host="postgres:5432" \
  name="mydb" \
  user="myuser" \
  password="hunter2"

# From a file
vault kv put secret/my-app/tls cert=@./cert.pem key=@./key.pem
```

### Read secrets

```bash
# Human-readable output
vault kv get secret/my-app/database

# Get a single field value (useful in scripts)
vault kv get -field=password secret/my-app/database

# JSON output
vault kv get -format=json secret/my-app/database
```

### List all secrets under a path

```bash
vault kv list secret/my-app/
vault kv list secret/        # list all apps
```

### Update a secret

KV v2 is versioned — updating creates a new version, the old one is kept:

```bash
vault kv put secret/my-app/database password="new-password"

# Check version history
vault kv metadata get secret/my-app/database
```

### Read a previous version

```bash
vault kv get -version=1 secret/my-app/database
```

### Delete a secret (soft delete — recoverable)

```bash
vault kv delete secret/my-app/database
# The latest version is marked deleted but data is retained.
# Read with -version=N still works.
```

### Undelete a soft-deleted secret

```bash
vault kv undelete -versions=2 secret/my-app/database
```

### Permanently destroy a version

```bash
vault kv destroy -versions=2 secret/my-app/database
# Data is gone — cannot be recovered.
```

### Delete all versions and metadata

```bash
vault kv metadata delete secret/my-app/database
# Permanently removes everything including history.
```

---

## Giving an app access to secrets

The access model is: **one AppRole per app, one policy per app**. Each app gets its own `role_id` and `secret_id`. It uses those credentials to get a short-lived token, then reads its secrets with that token.

### Dockerized apps

#### Step 1 — Create the AppRole

Run this on the server from `~/infra-vault`:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=hvs.ZZZZZZZZ...   # ops token

# Read-only access (default):
./scripts/new-app-role.sh my-app

# Read + write access:
./scripts/new-app-role.sh my-app --readwrite
```

Output:

```
AppRole created for: my-app
  VAULT_ROLE_ID   = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  VAULT_SECRET_ID = yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
```

This also creates `vault/policies/my-app.hcl`. Commit that file so it's tracked in git and applied by CI/CD going forward.

#### Step 2 — Store the app's secrets

```bash
vault kv put secret/my-app/config \
  DB_URL="postgres://user:pass@db:5432/mydb" \
  REDIS_URL="redis://redis:6379" \
  API_KEY="sk-..."
```

#### Step 3 — Connect the app's Docker Compose to vault-net

In the app's `docker-compose.yml`:

```yaml
services:
  my-app:
    image: my-app:latest
    environment:
      VAULT_ADDR: http://vault:8200
      VAULT_ROLE_ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   # from step 1
      VAULT_SECRET_ID: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy # from step 1
    networks:
      - vault-net
      - default          # keep the app's own network too

networks:
  vault-net:
    external: true       # joins the existing vault-net network
```

The app now reaches Vault at `http://vault:8200`.

#### Step 4 — Authenticate from the app

The app exchanges its `role_id` + `secret_id` for a token at startup, then reads secrets using that token. The token is valid for 1 hour and must be renewed or the login repeated.

**Python (using [hvac](https://hvac.readthedocs.io/)):**

```python
import hvac
import os

client = hvac.Client(url=os.environ["VAULT_ADDR"])
client.auth.approle.login(
    role_id=os.environ["VAULT_ROLE_ID"],
    secret_id=os.environ["VAULT_SECRET_ID"],
)

secret = client.secrets.kv.v2.read_secret_version(
    path="my-app/config",
    mount_point="secret",
)
config = secret["data"]["data"]   # {"DB_URL": "...", "API_KEY": "..."}
```

**Go (using [vault-client-go](https://github.com/hashicorp/vault-client-go)):**

```go
import (
    "context"
    "os"
    vault "github.com/hashicorp/vault-client-go"
    "github.com/hashicorp/vault-client-go/schema"
)

client, _ := vault.New(vault.WithAddress(os.Getenv("VAULT_ADDR")))

resp, _ := client.Auth.AppRoleLogin(context.Background(),
    schema.AppRoleLoginRequest{
        RoleId:   os.Getenv("VAULT_ROLE_ID"),
        SecretId: os.Getenv("VAULT_SECRET_ID"),
    },
)
client.SetToken(resp.Auth.ClientToken)

secret, _ := client.Secrets.KvV2Read(context.Background(), "my-app/config",
    vault.WithMountPath("secret"),
)
data := secret.Data.Data   // map[string]interface{}
```

**Shell / curl (for scripts):**

```bash
TOKEN=$(curl -sf http://vault:8200/v1/auth/approle/login \
  -d "{\"role_id\":\"$VAULT_ROLE_ID\",\"secret_id\":\"$VAULT_SECRET_ID\"}" \
  | jq -r '.auth.client_token')

curl -sf -H "X-Vault-Token: $TOKEN" \
  http://vault:8200/v1/secret/data/my-app/config \
  | jq '.data.data'
```

> **KV v2 path note:** The CLI command `vault kv get secret/my-app/config` is shorthand. The raw HTTP API path is `/v1/secret/data/my-app/config` (note the extra `data/`). This is a common gotcha.

---

### Apps installed on the host

Host-installed services (Prometheus, Kafka, apps running directly on the OS) reach Vault at `http://127.0.0.1:8200`.

#### Create the AppRole (same as above, just use the host address)

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=hvs.ZZZZZZZZ...
./scripts/new-app-role.sh prometheus
```

#### Use in a shell script or systemd service

Create `/etc/vault/prometheus.env` with restricted permissions:

```bash
sudo mkdir -p /etc/vault
sudo tee /etc/vault/prometheus.env <<EOF
VAULT_ADDR=http://127.0.0.1:8200
VAULT_ROLE_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
VAULT_SECRET_ID=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
EOF
sudo chmod 600 /etc/vault/prometheus.env
sudo chown prometheus:prometheus /etc/vault/prometheus.env
```

In the systemd unit file:

```ini
[Service]
EnvironmentFile=/etc/vault/prometheus.env
ExecStartPre=/usr/local/bin/vault-login.sh   # fetches token, writes to /run/vault-token
```

---

## Managing AppRoles

Use these with `VAULT_ADDR` and `VAULT_TOKEN` set (ops token is sufficient).

```bash
# List all app roles
vault list auth/approle/role/

# Inspect a role's settings (TTLs, policies)
vault read auth/approle/role/my-app

# Generate a new secret_id (rotate credentials)
vault write -f auth/approle/role/my-app/secret-id

# List active secret_id accessors (does NOT show the secret_id itself)
vault list auth/approle/role/my-app/secret-id

# Revoke a specific secret_id by its accessor
vault write auth/approle/role/my-app/secret-id/destroy \
  secret_id_accessor=<accessor-from-list>

# Revoke ALL secret_ids for a role (forces re-auth for all instances)
vault write -f auth/approle/role/my-app/secret-id/destroy-all

# Delete an app role entirely
vault delete auth/approle/role/my-app
```

### Rotating an app's credentials

If a `secret_id` is leaked, rotate it:

1. Generate a new one: `vault write -f -field=secret_id auth/approle/role/my-app/secret-id`
2. Update the app's environment with the new value and restart the app
3. Revoke the old accessor: `vault write auth/approle/role/my-app/secret-id/destroy secret_id_accessor=<old-accessor>`

---

## Managing tokens

```bash
# Look up your current token
vault token lookup

# Look up another token
vault token lookup hvs.XXXXXXXX

# Create a token with a specific policy and TTL
vault token create -policy=ops -ttl=24h -display-name=temporary-admin

# Create a token that never expires (use sparingly)
vault token create -policy=ops -ttl=0

# Revoke a token
vault token revoke hvs.XXXXXXXX

# List all token accessors (does NOT expose the tokens themselves)
vault list auth/token/accessors

# Look up a token by its accessor (to check expiry, policies, etc.)
vault token lookup -accessor <accessor>

# Revoke by accessor (useful when you don't have the token)
vault token revoke -accessor <accessor>
```

---

## Managing policies

Policies are HCL files in `vault/policies/`. They are applied automatically on every deploy via `scripts/apply-policies.sh`.

### View an existing policy

```bash
vault policy read my-app
vault policy list
```

### Add or update a policy

1. Edit or create `vault/policies/my-app.hcl`
2. Commit and push to `main` — CI/CD applies it automatically

Or apply immediately without a deploy:

```bash
vault policy write my-app vault/policies/my-app.hcl
```

### Policy path syntax reference

```hcl
# Read secrets at secret/my-app/ and below
path "secret/data/my-app/*" {
  capabilities = ["read", "list"]
}

# Allow creating and updating (for apps that write their own secrets)
path "secret/data/my-app/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Allow reading metadata (version history)
path "secret/metadata/my-app/*" {
  capabilities = ["read", "list"]
}
```

> The `secret/data/` prefix is required for KV v2 in policies, even though the CLI hides it. `vault kv get secret/my-app/config` → policy path must be `secret/data/my-app/config`.

### Delete a policy

```bash
vault policy delete my-app
```

This does not revoke tokens that were issued with this policy — they keep working until they expire. Revoke them explicitly if needed.

---

## Vault UI

The web UI is enabled. To access it, create an SSH tunnel from your local machine:

```bash
ssh -L 8200:127.0.0.1:8200 user@your-server
```

Then open `http://localhost:8200/ui` in a browser and log in with a token.

The UI lets you browse secrets, view policies, inspect tokens, and watch the audit log — useful for day-to-day operations without memorizing CLI commands.

---

## Rotating the unseal key

You cannot change the unseal key in place. To rotate it you must re-key:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-or-admin-token>

# Start re-key operation
vault operator rekey -init -key-shares=1 -key-threshold=1

# Copy the nonce from the output, then provide the current key
vault operator rekey -nonce=<nonce> <current-unseal-key>

# Output is the new unseal key — save it immediately
```

After re-keying:
1. Update `VAULT_UNSEAL_KEY` in the server's `.env` file
2. Restart the vault-unseal container: `docker restart vault-unseal`
3. Update the `VAULT_UNSEAL_KEY` GitHub Secret

---

## Upgrading Vault

1. Update the image tag in `docker/docker-compose.yml` (e.g., `hashicorp/vault:1.18`)
2. Commit and push to `main` — the deploy workflow pulls the new image and restarts containers
3. On restart, vault-unseal will automatically unseal the upgraded instance

Always check the [Vault upgrade guide](https://developer.hashicorp.com/vault/docs/upgrading) for breaking changes before bumping versions.

---

## Troubleshooting

### Vault is sealed after a restart

```bash
docker logs vault-unseal   # check if key is wrong or Vault isn't reachable
```

Manual unseal:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault operator unseal   # prompts for key
```

### vault-unseal keeps logging "unseal failed"

The `VAULT_UNSEAL_KEY` in `.env` is wrong or missing. Verify it matches what `vault operator init` printed, then restart:

```bash
docker restart vault-unseal
```

### "permission denied" when reading a secret

The token being used doesn't have a policy that covers that path. Check what policies the token has:

```bash
vault token lookup <token>   # shows policies field
vault policy read <policy-name>
```

Then either update the policy in `vault/policies/<app>.hcl` or grant the token an additional policy.

### App can't reach Vault ("connection refused")

For Docker apps: confirm the app's compose file has `vault-net` listed as an external network and the container is actually joined to it:

```bash
docker network inspect vault-net
```

For host apps: confirm Vault is running and listening:

```bash
curl http://127.0.0.1:8200/v1/sys/health
```

### Check Vault status and container health

```bash
make status
docker compose -f docker/docker-compose.yml ps
docker logs vault --tail=50
```

### View the audit log

Every secret read, write, token login, and policy change is logged:

```bash
docker exec vault cat /vault/logs/audit.log | jq '.' | less
```
