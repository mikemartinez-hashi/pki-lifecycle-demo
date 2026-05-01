# ─────────────────────────────────────────────────────────────────────────────
# vault.tf — intentionally empty
#
# Vault PKI and AppRole configuration is handled by:
#   scripts/setup-vault-pki.sh
#
# Run that script first (with VAULT_ADDR, VAULT_NAMESPACE, and VAULT_TOKEN
# exported), then copy the output Role IDs / Secret IDs into your HCP TF
# workspace variables before running terraform apply.
# ─────────────────────────────────────────────────────────────────────────────
