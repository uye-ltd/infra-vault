# Monitoring and operations access — for CI/CD pipeline tokens and human operators.
# Can read all secrets and manage policies, but cannot modify auth methods or system config.

path "secret/*" {
  capabilities = ["read", "list"]
}

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/health" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "auth/approle/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
