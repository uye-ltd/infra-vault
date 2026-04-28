# Template for per-application policies.
# Copy this file to vault/policies/<app-name>.hcl and replace "app-example" with the app name.
# Use scripts/new-app-role.sh to generate this automatically.

path "secret/data/app-example/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/app-example/*" {
  capabilities = ["read", "list"]
}
