# ────────────────────────────────────────────────────────────────────────────
# vault.tf — All Vault PKI + Auth configuration managed by Terraform
#
# This file configures:
#   - Root CA          (pki/)
#   - Intermediate CA  (pki_int/)
#   - PKI Roles        (iis-role, apache-role)
#   - Vault Policies
#   - AppRole auth + Role IDs / Secret IDs
# ────────────────────────────────────────────────────────────────────────────

# ─── PKI Root CA ──────────────────────────────────────────────────────────────

resource "vault_mount" "pki_root" {
  path                      = "pki"
  type                      = "pki"
  description               = "PKI Demo - Root Certificate Authority"
  default_lease_ttl_seconds = 315360000 # 10 years
  max_lease_ttl_seconds     = 315360000
}

resource "vault_pki_secret_backend_root_cert" "root_ca" {
  backend      = vault_mount.pki_root.path
  type         = "internal"
  common_name  = var.pki_root_cn
  ttl          = "315360000"
  key_type     = "rsa"
  key_bits     = 4096
  organization = "HashiCorp Demo"
  country      = "US"
}

resource "vault_pki_secret_backend_config_urls" "root_urls" {
  backend                 = vault_mount.pki_root.path
  issuing_certificates    = ["${var.TFC_VAULT_ADDR}/v1/pki/ca"]
  crl_distribution_points = ["${var.TFC_VAULT_ADDR}/v1/pki/crl"]
}

# ─── PKI Intermediate CA ──────────────────────────────────────────────────────

resource "vault_mount" "pki_int" {
  path                      = "pki_int"
  type                      = "pki"
  description               = "PKI Demo - Intermediate Certificate Authority"
  default_lease_ttl_seconds = 94608000 # 3 years
  max_lease_ttl_seconds     = 94608000
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int_csr" {
  backend      = vault_mount.pki_int.path
  type         = "internal"
  common_name  = var.pki_int_cn
  key_type     = "rsa"
  key_bits     = 4096
  organization = "HashiCorp Demo"
  country      = "US"
}

# Sign the Intermediate CSR with the Root CA
resource "vault_pki_secret_backend_root_sign_intermediate" "int_signed" {
  backend     = vault_mount.pki_root.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.int_csr.csr
  common_name = var.pki_int_cn
  ttl         = "94608000" # 3 years
}

# Import the signed Intermediate certificate back into pki_int
resource "vault_pki_secret_backend_intermediate_set_signed" "int_import" {
  backend     = vault_mount.pki_int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int_signed.certificate
}

resource "vault_pki_secret_backend_config_urls" "int_urls" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["${var.TFC_VAULT_ADDR}/v1/pki_int/ca"]
  crl_distribution_points = ["${var.TFC_VAULT_ADDR}/v1/pki_int/crl"]

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int_import]
}

# ─── PKI Roles ────────────────────────────────────────────────────────────────

resource "vault_pki_secret_backend_role" "iis_role" {
  backend          = vault_mount.pki_int.path
  name             = "iis-role"
  ttl              = "720h"   # 30 days default
  max_ttl          = "8760h"  # 1 year max
  allow_any_name   = false
  allow_subdomains = true
  allowed_domains  = ["demo.internal", "windows.internal"]
  key_type         = "rsa"
  key_bits         = 2048
  key_usage        = ["DigitalSignature", "KeyEncipherment"]
  ext_key_usage    = ["ServerAuth"]
  require_cn       = true

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int_import]
}

resource "vault_pki_secret_backend_role" "apache_role" {
  backend          = vault_mount.pki_int.path
  name             = "apache-role"
  ttl              = "720h"
  max_ttl          = "8760h"
  allow_any_name   = false
  allow_subdomains = true
  allowed_domains  = ["demo.internal", "linux.internal"]
  key_type         = "rsa"
  key_bits         = 2048
  key_usage        = ["DigitalSignature", "KeyEncipherment"]
  ext_key_usage    = ["ServerAuth"]
  require_cn       = true

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int_import]
}

# ─── Vault Policies ───────────────────────────────────────────────────────────

resource "vault_policy" "pki_iis" {
  name   = "pki-iis-policy"
  policy = file("/configs/pki-policy-iis.hcl")
}

resource "vault_policy" "pki_apache" {
  name   = "pki-apache-policy"
  policy = file("/configs/pki-policy-apache.hcl")
}

# ─── AppRole Auth Method ──────────────────────────────────────────────────────

resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = "approle"
  description = "AppRole auth for Vault Agent (PKI Demo)"
}

# IIS AppRole
resource "vault_approle_auth_backend_role" "iis" {
  backend        = vault_auth_backend.approle.path
  role_name      = "iis-vault-agent"
  token_policies = [vault_policy.pki_iis.name]
  token_ttl      = 3600   # 1 hour
  token_max_ttl  = 86400  # 24 hours
  secret_id_ttl  = 0      # non-expiring for demo
}

resource "vault_approle_auth_backend_role_secret_id" "iis_secret_id" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.iis.role_name
}

# Apache AppRole
resource "vault_approle_auth_backend_role" "apache" {
  backend        = vault_auth_backend.approle.path
  role_name      = "apache-vault-agent"
  token_policies = [vault_policy.pki_apache.name]
  token_ttl      = 3600
  token_max_ttl  = 86400
  secret_id_ttl  = 0
}

resource "vault_approle_auth_backend_role_secret_id" "apache_secret_id" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.apache.role_name
}
