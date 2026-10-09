# Least privilege: the operator may read application secrets and nothing else.
# It cannot write, list other paths, or touch Vault's own configuration.
path "secret/data/app/*" {
  capabilities = ["read"]
}
