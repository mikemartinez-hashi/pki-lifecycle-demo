#!/usr/bin/env bash
# =============================================================================
# cleanup-vault-pki.sh
# Removes all Vault PKI Demo resources from HCP Vault post-demo.
#
# What this removes:
#   - AppRole roles (iis-vault-agent, apache-vault-agent)
#   - Vault policies (pki-iis-policy, pki-apache-policy)
#   - PKI Intermediate CA mount (pki_int/)  ← revokes ALL issued certs
#   - PKI Root CA mount (pki/)
#
# What this does NOT touch:
#   - The AppRole auth method itself (left enabled in case other demos use it)
#   - AWS infrastructure (run: terraform destroy for that)
#
# Prerequisites:
#   export VAULT_ADDR="https://vault-demo-cluster-public-vault-b71960ee.491753e4.z1.hashicorp.cloud:8200"
#   export VAULT_NAMESPACE="admin"
#   export VAULT_TOKEN="<your admin token>"
#
# Run from the repo root:
#   chmod +x scripts/cleanup-vault-pki.sh
#   ./scripts/cleanup-vault-pki.sh
# =============================================================================
set -euo pipefail

# ─── Color helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }

# ─── Validate environment ─────────────────────────────────────────────────────
[[ -z "${VAULT_ADDR:-}"  ]] && error "VAULT_ADDR is not set."
[[ -z "${VAULT_TOKEN:-}" ]] && error "VAULT_TOKEN is not set."
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

info "Vault address:   $VAULT_ADDR"
info "Vault namespace: $VAULT_NAMESPACE"

vault status > /dev/null 2>&1 || error "Cannot reach Vault at $VAULT_ADDR"
success "Vault connectivity confirmed."

# ─── Confirmation prompt ──────────────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                  ⚠  POST-DEMO CLEANUP ⚠                    ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  This will permanently remove:                               ║${NC}"
echo -e "${RED}║    • Both PKI mounts (pki/ and pki_int/)                     ║${NC}"
echo -e "${RED}║    • All certificates issued by these CAs                    ║${NC}"
echo -e "${RED}║    • AppRole roles for IIS and Apache agents                 ║${NC}"
echo -e "${RED}║    • Vault policies for this demo                            ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  AWS infrastructure is NOT touched — run terraform destroy   ║${NC}"
echo -e "${RED}║  separately if needed.                                       ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "Type 'yes' to continue with cleanup: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { warn "Cleanup cancelled."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
header "Step 1: Revoke AppRole Secret IDs"
# ══════════════════════════════════════════════════════════════════════════════

APPROLE_PATH="approle"

for ROLE in "iis-vault-agent" "apache-vault-agent"; do
    if vault read "auth/${APPROLE_PATH}/role/${ROLE}" > /dev/null 2>&1; then
        info "Listing and revoking active secret IDs for $ROLE ..."

        # Get all secret ID accessors and revoke them
        ACCESSORS=$(vault list -format=json "auth/${APPROLE_PATH}/role/${ROLE}/secret-id" 2>/dev/null \
            | jq -r '.[]' 2>/dev/null || echo "")

        if [[ -n "$ACCESSORS" ]]; then
            while IFS= read -r ACCESSOR; do
                vault write -force "auth/${APPROLE_PATH}/role/${ROLE}/secret-id-accessor/destroy" \
                    secret_id_accessor="$ACCESSOR" > /dev/null 2>&1 && \
                    info "  Revoked secret ID accessor: $ACCESSOR"
            done <<< "$ACCESSORS"
        else
            info "  No active secret IDs found for $ROLE."
        fi
    else
        skip "AppRole role $ROLE not found — skipping."
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
header "Step 2: Delete AppRole Roles"
# ══════════════════════════════════════════════════════════════════════════════

for ROLE in "iis-vault-agent" "apache-vault-agent"; do
    if vault read "auth/${APPROLE_PATH}/role/${ROLE}" > /dev/null 2>&1; then
        vault delete "auth/${APPROLE_PATH}/role/${ROLE}"
        success "Deleted AppRole role: $ROLE"
    else
        skip "AppRole role $ROLE not found — already removed."
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
header "Step 3: Delete Vault Policies"
# ══════════════════════════════════════════════════════════════════════════════

for POLICY in "pki-iis-policy" "pki-apache-policy"; do
    if vault policy read "$POLICY" > /dev/null 2>&1; then
        vault policy delete "$POLICY"
        success "Deleted policy: $POLICY"
    else
        skip "Policy $POLICY not found — already removed."
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
header "Step 4: Disable PKI Intermediate CA (pki_int/)"
# Disabling a PKI mount revokes ALL certificates it has issued
# ══════════════════════════════════════════════════════════════════════════════

if vault secrets list -format=json | grep -q '"pki_int/"'; then
    # Count certs before nuking for the summary
    CERT_COUNT=$(vault list -format=json pki_int/certs 2>/dev/null | jq 'length' 2>/dev/null || echo "unknown")
    info "Disabling pki_int/ — this will revoke approximately $CERT_COUNT certificate(s)..."
    vault secrets disable pki_int
    success "pki_int/ disabled. All issued certificates have been revoked."
else
    skip "pki_int/ not found — already removed."
fi

# ══════════════════════════════════════════════════════════════════════════════
header "Step 5: Disable PKI Root CA (pki/)"
# ══════════════════════════════════════════════════════════════════════════════

if vault secrets list -format=json | grep -q '"pki/"'; then
    info "Disabling pki/ Root CA..."
    vault secrets disable pki
    success "pki/ disabled."
else
    skip "pki/ not found — already removed."
fi

# ══════════════════════════════════════════════════════════════════════════════
header "Step 6: Clean up local artifacts"
# ══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_ROOT}/.vault-outputs.env"

if [[ -f "$ENV_FILE" ]]; then
    rm "$ENV_FILE"
    success "Removed .vault-outputs.env"
else
    skip ".vault-outputs.env not found — nothing to remove."
fi

# Clean up temp CSR/cert files from setup
for TMP_FILE in /tmp/root_ca.pem /tmp/pki_int.csr /tmp/pki_int_signed.pem; do
    [[ -f "$TMP_FILE" ]] && rm "$TMP_FILE" && info "Removed $TMP_FILE"
done

# ══════════════════════════════════════════════════════════════════════════════
header "Cleanup Complete"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}✔ All Vault PKI demo resources have been removed.${NC}"
echo ""
echo -e "${YELLOW}Remaining steps (if needed):${NC}"
echo "  • Destroy AWS infrastructure:"
echo "      terraform destroy"
echo ""
echo "  • Clear HCP TF workspace variables:"
echo "      iis_role_id, iis_secret_id, apache_role_id, apache_secret_id"
echo ""
echo "  • The AppRole auth method (auth/approle/) was intentionally left"
echo "    enabled in case other demos share it."
echo "    To fully remove it:  vault auth disable approle"
echo ""
