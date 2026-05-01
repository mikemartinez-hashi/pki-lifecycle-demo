#!/usr/bin/env bash
# =============================================================================
# setup-vault-pki.sh
# Configures Vault PKI Secrets Engine and AppRole auth for the PKI Lifecycle Demo
#
# Prerequisites:
#   export VAULT_ADDR="https://vault-demo-cluster-public-vault-b71960ee.491753e4.z1.hashicorp.cloud:8200"
#   export VAULT_NAMESPACE="admin"
#   export VAULT_TOKEN="<your admin token>"
#
# Run from the repo root:
#   chmod +x scripts/setup-vault-pki.sh
#   ./scripts/setup-vault-pki.sh
#
# At the end, copy the output Role IDs + Secret IDs into your HCP TF
# workspace variables (iis_role_id, iis_secret_id, apache_role_id, apache_secret_id)
# =============================================================================
set -euo pipefail

# ─── Color helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }

# ─── Validate environment ─────────────────────────────────────────────────────
[[ -z "${VAULT_ADDR:-}"  ]] && error "VAULT_ADDR is not set. Export it before running this script."
[[ -z "${VAULT_TOKEN:-}" ]] && error "VAULT_TOKEN is not set. Export it before running this script."

# Default namespace to admin if not set (HCP Vault default)
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

info "Vault address:   $VAULT_ADDR"
info "Vault namespace: $VAULT_NAMESPACE"

# Verify connectivity
vault status > /dev/null 2>&1 || error "Cannot reach Vault at $VAULT_ADDR — check VAULT_ADDR and VAULT_TOKEN."
success "Vault connectivity confirmed."

# ─── Configuration ────────────────────────────────────────────────────────────
PKI_ROOT_PATH="pki"
PKI_INT_PATH="pki_int"
PKI_ROOT_CN="Vault Demo Root CA"
PKI_INT_CN="Vault Demo Intermediate CA"
APPROLE_PATH="approle"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ══════════════════════════════════════════════════════════════════════════════
header "Step 1: Root CA (pki/)"
# ══════════════════════════════════════════════════════════════════════════════

info "Enabling PKI secrets engine at $PKI_ROOT_PATH/ ..."
if vault secrets list -format=json | grep -q "\"${PKI_ROOT_PATH}/\""; then
    warn "$PKI_ROOT_PATH/ already enabled — skipping enable."
else
    vault secrets enable \
        -path="$PKI_ROOT_PATH" \
        -description="PKI Demo - Root Certificate Authority" \
        -max-lease-ttl="315360000" \
        pki
    success "PKI root engine enabled."
fi

info "Tuning Root CA max TTL (10 years)..."
vault secrets tune -max-lease-ttl=315360000 "$PKI_ROOT_PATH/"

info "Generating Root CA certificate..."
vault write -format=json "${PKI_ROOT_PATH}/root/generate/internal" \
    common_name="$PKI_ROOT_CN" \
    organization="HashiCorp Demo" \
    country="US" \
    key_type="rsa" \
    key_bits=4096 \
    ttl="315360000" \
    | jq -r '.data.certificate' > /tmp/root_ca.pem

success "Root CA generated. Certificate saved to /tmp/root_ca.pem"

info "Configuring Root CA CRL and issuing URLs..."
vault write "${PKI_ROOT_PATH}/config/urls" \
    issuing_certificates="${VAULT_ADDR}/v1/${PKI_ROOT_PATH}/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/${PKI_ROOT_PATH}/crl"
success "Root CA URLs configured."

# ══════════════════════════════════════════════════════════════════════════════
header "Step 2: Intermediate CA (pki_int/)"
# ══════════════════════════════════════════════════════════════════════════════

info "Enabling PKI secrets engine at $PKI_INT_PATH/ ..."
if vault secrets list -format=json | grep -q "\"${PKI_INT_PATH}/\""; then
    warn "$PKI_INT_PATH/ already enabled — skipping enable."
else
    vault secrets enable \
        -path="$PKI_INT_PATH" \
        -description="PKI Demo - Intermediate Certificate Authority" \
        -max-lease-ttl="94608000" \
        pki
    success "PKI intermediate engine enabled."
fi

info "Tuning Intermediate CA max TTL (3 years)..."
vault secrets tune -max-lease-ttl=94608000 "$PKI_INT_PATH/"

info "Generating Intermediate CA CSR..."
vault write -format=json "${PKI_INT_PATH}/intermediate/generate/internal" \
    common_name="$PKI_INT_CN" \
    organization="HashiCorp Demo" \
    country="US" \
    key_type="rsa" \
    key_bits=4096 \
    | jq -r '.data.csr' > /tmp/pki_int.csr

success "Intermediate CSR generated at /tmp/pki_int.csr"

info "Signing Intermediate CSR with Root CA..."
vault write -format=json "${PKI_ROOT_PATH}/root/sign-intermediate" \
    csr=@/tmp/pki_int.csr \
    common_name="$PKI_INT_CN" \
    ttl="94608000" \
    format="pem_bundle" \
    | jq -r '.data.certificate' > /tmp/pki_int_signed.pem

success "Intermediate certificate signed at /tmp/pki_int_signed.pem"

info "Importing signed Intermediate certificate..."
vault write "${PKI_INT_PATH}/intermediate/set-signed" \
    certificate=@/tmp/pki_int_signed.pem
success "Intermediate certificate imported."

info "Configuring Intermediate CA CRL and issuing URLs..."
vault write "${PKI_INT_PATH}/config/urls" \
    issuing_certificates="${VAULT_ADDR}/v1/${PKI_INT_PATH}/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/${PKI_INT_PATH}/crl"
success "Intermediate CA URLs configured."

# ══════════════════════════════════════════════════════════════════════════════
header "Step 3: PKI Roles"
# ══════════════════════════════════════════════════════════════════════════════

info "Creating IIS role (iis-role) ..."
vault write "${PKI_INT_PATH}/roles/iis-role" \
    allowed_domains="demo.internal,windows.internal" \
    allow_subdomains=true \
    allow_any_name=false \
    key_type="rsa" \
    key_bits=2048 \
    key_usage="DigitalSignature,KeyEncipherment" \
    ext_key_usage="ServerAuth" \
    require_cn=true \
    ttl="720h" \
    max_ttl="8760h"
success "IIS role created."

info "Creating Apache role (apache-role) ..."
vault write "${PKI_INT_PATH}/roles/apache-role" \
    allowed_domains="demo.internal,linux.internal" \
    allow_subdomains=true \
    allow_any_name=false \
    key_type="rsa" \
    key_bits=2048 \
    key_usage="DigitalSignature,KeyEncipherment" \
    ext_key_usage="ServerAuth" \
    require_cn=true \
    ttl="720h" \
    max_ttl="8760h"
success "Apache role created."

# Quick smoke test
info "Smoke test — issuing a test certificate from iis-role ..."
vault write -format=json "${PKI_INT_PATH}/issue/iis-role" \
    common_name="test.demo.internal" \
    ttl="1h" \
    | jq -r '.data.certificate' | openssl x509 -noout -subject -dates
success "Test certificate issued successfully."

# ══════════════════════════════════════════════════════════════════════════════
header "Step 4: Vault Policies"
# ══════════════════════════════════════════════════════════════════════════════

IIS_POLICY_FILE="${REPO_ROOT}/configs/pki-policy-iis.hcl"
APACHE_POLICY_FILE="${REPO_ROOT}/configs/pki-policy-apache.hcl"

[[ -f "$IIS_POLICY_FILE" ]]    || error "Policy file not found: $IIS_POLICY_FILE"
[[ -f "$APACHE_POLICY_FILE" ]] || error "Policy file not found: $APACHE_POLICY_FILE"

info "Writing pki-iis-policy ..."
vault policy write pki-iis-policy "$IIS_POLICY_FILE"
success "pki-iis-policy written."

info "Writing pki-apache-policy ..."
vault policy write pki-apache-policy "$APACHE_POLICY_FILE"
success "pki-apache-policy written."

# ══════════════════════════════════════════════════════════════════════════════
header "Step 5: AppRole Auth + Roles"
# ══════════════════════════════════════════════════════════════════════════════

info "Enabling AppRole auth method..."
if vault auth list -format=json | grep -q "\"${APPROLE_PATH}/\""; then
    warn "AppRole already enabled at ${APPROLE_PATH}/ — skipping."
else
    vault auth enable -path="$APPROLE_PATH" approle
    success "AppRole auth enabled."
fi

# IIS AppRole
info "Creating IIS Vault Agent AppRole (iis-vault-agent) ..."
vault write "auth/${APPROLE_PATH}/role/iis-vault-agent" \
    token_policies="pki-iis-policy" \
    token_ttl="1h" \
    token_max_ttl="24h" \
    secret_id_ttl=0
success "iis-vault-agent role created."

IIS_ROLE_ID=$(vault read -format=json "auth/${APPROLE_PATH}/role/iis-vault-agent/role-id" | jq -r '.data.role_id')
IIS_SECRET_ID=$(vault write -format=json -f "auth/${APPROLE_PATH}/role/iis-vault-agent/secret-id" | jq -r '.data.secret_id')
success "IIS Role ID and Secret ID generated."

# Apache AppRole
info "Creating Apache Vault Agent AppRole (apache-vault-agent) ..."
vault write "auth/${APPROLE_PATH}/role/apache-vault-agent" \
    token_policies="pki-apache-policy" \
    token_ttl="1h" \
    token_max_ttl="24h" \
    secret_id_ttl=0
success "apache-vault-agent role created."

APACHE_ROLE_ID=$(vault read -format=json "auth/${APPROLE_PATH}/role/apache-vault-agent/role-id" | jq -r '.data.role_id')
APACHE_SECRET_ID=$(vault write -format=json -f "auth/${APPROLE_PATH}/role/apache-vault-agent/secret-id" | jq -r '.data.secret_id')
success "Apache Role ID and Secret ID generated."

# ══════════════════════════════════════════════════════════════════════════════
header "Setup Complete — Copy these into HCP TF Workspace Variables"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│         HCP Terraform Workspace Variables                │${NC}"
echo -e "${GREEN}├──────────────────────┬──────────────────────────────────┤${NC}"
echo -e "${GREEN}│ Variable             │ Value                            │${NC}"
echo -e "${GREEN}├──────────────────────┼──────────────────────────────────┤${NC}"
printf "${GREEN}│${NC} %-20s ${GREEN}│${NC} %-32s ${GREEN}│${NC}\n" "iis_role_id"      "$IIS_ROLE_ID"
printf "${GREEN}│${NC} %-20s ${GREEN}│${NC} %-32s ${GREEN}│${NC}\n" "iis_secret_id"    "$(echo "$IIS_SECRET_ID" | cut -c1-20)... [SENSITIVE]"
printf "${GREEN}│${NC} %-20s ${GREEN}│${NC} %-32s ${GREEN}│${NC}\n" "apache_role_id"   "$APACHE_ROLE_ID"
printf "${GREEN}│${NC} %-20s ${GREEN}│${NC} %-32s ${GREEN}│${NC}\n" "apache_secret_id" "$(echo "$APACHE_SECRET_ID" | cut -c1-20)... [SENSITIVE]"
echo -e "${GREEN}└──────────────────────┴──────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}Full values (keep these secure):${NC}"
echo "iis_role_id      = $IIS_ROLE_ID"
echo "iis_secret_id    = $IIS_SECRET_ID"
echo "apache_role_id   = $APACHE_ROLE_ID"
echo "apache_secret_id = $APACHE_SECRET_ID"
echo ""
echo -e "${CYAN}Mark iis_secret_id and apache_secret_id as SENSITIVE in the HCP TF workspace.${NC}"
echo ""

# Optionally write to a .env file for convenience
ENV_FILE="${REPO_ROOT}/.vault-outputs.env"
cat > "$ENV_FILE" << EOF
# Generated by setup-vault-pki.sh — DO NOT COMMIT (already in .gitignore)
# Add these as Terraform Variables in your HCP TF workspace.
export TF_VAR_iis_role_id="$IIS_ROLE_ID"
export TF_VAR_iis_secret_id="$IIS_SECRET_ID"
export TF_VAR_apache_role_id="$APACHE_ROLE_ID"
export TF_VAR_apache_secret_id="$APACHE_SECRET_ID"
EOF
success "Values also saved to $ENV_FILE (gitignored)"
echo -e "${YELLOW}Next step: terraform apply${NC}"
