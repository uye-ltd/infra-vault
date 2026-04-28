ui            = true
disable_mlock = true  # recommended for Docker; many VPS kernels ignore cap_add: IPC_LOCK silently

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-node-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true # safe: port is bound to 127.0.0.1 on the host; TLS handled by reverse proxy
}

# Override via VAULT_API_ADDR env var when a public domain is configured
api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
