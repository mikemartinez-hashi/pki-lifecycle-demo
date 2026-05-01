# Vault policy — Apache / Linux Vault Agent
# Grants permission to issue certificates from pki_int using the apache-role

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/approle/login" {
  capabilities = ["create", "read"]
}

path "pki_int/issue/apache-role" {
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
