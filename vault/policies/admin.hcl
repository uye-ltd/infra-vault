# Break-glass only. Token with this policy should have a short TTL and be revoked after use.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
