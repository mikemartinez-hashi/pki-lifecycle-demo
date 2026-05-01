# Vault policy — IIS / Windows Vault Agent
# Grants permission to issue certificates from pki_int using the iis-role

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/approle/login" {
  capabilities = ["create", "read"]
}

path "pki_int/issue/iis-role" {
  capabilities = ["create", "update"]
}

path "pki_int/ca" {
  capabilities = ["read"]
}

path "pki_int/ca_chain" {
  capabilities = ["read"]
}

path "pki_int/crl" {
  capabilities = ["read"]
}
