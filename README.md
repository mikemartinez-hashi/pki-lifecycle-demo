# Vault PKI Lifecycle Demo (30-Minute Version)

## Overview

End-to-end PKI certificate lifecycle demo using HashiCorp Vault's PKI Secrets Engine.
**A single `terraform apply` deploys everything** — Vault PKI configuration, AppRole auth, and two EC2 servers with Vault Agent running and managing TLS certificates automatically.

| Platform | Method | What it shows |
|----------|--------|---------------|
| **IIS (Windows Server 2025)** | Vault Agent + AppRole | Cert issued → Windows Cert Store → IIS HTTPS binding |
| **Apache (Amazon Linux 2023)** | Vault Agent + AppRole | Cert issued → Apache SSL → auto-reloaded on renewal |

> No NetScaler. No Kubernetes (deferred). Terraform-first, HCP Vault + HCP Terraform.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  HCP Vault (namespace: admin)                 │
│                                                              │
│   pki/        Root CA  (10 yr)                               │
│      └──▶  pki_int/  Intermediate CA  (3 yr)                 │
│                  ├── iis-role    (30d TTL, demo.internal)     │
│                  └── apache-role (30d TTL, demo.internal)     │
│                                                              │
│   auth/approle/                                              │
│        ├── iis-vault-agent    → Role ID + Secret ID          │
│        └── apache-vault-agent → Role ID + Secret ID          │
└──────────────────────────────────────────────────────────────┘
                 │                         │
    Vault Agent (Windows Service)   Vault Agent (systemd)
                 │                         │
    ┌────────────▼────────────┐  ┌─────────▼────────────┐
    │   Windows Server 2025   │  │   Amazon Linux 2023   │
    │   IIS + HTTPS on 443    │  │   Apache + SSL 443    │
    └─────────────────────────┘  └──────────────────────┘
```

---

## Prerequisites

- **HCP Vault** cluster accessible (namespace: `admin`)
- **HCP Terraform** account with an organization already created
- **AWS credentials** (access key + secret, or STS session token)
- **EC2 Key Pair** already created in your target AWS region

---

## Quick Start — HCP Terraform

### 1. Edit `main.tf` — set your HCP TF org name

```hcl
# terraform/main.tf
cloud {
  organization = "YOUR_HCP_TF_ORG"   # ← your actual org name
  workspaces {
    name = "pki-lifecycle-demo"
  }
}
```

> **Create the workspace first in HCP TF:** New Workspace → **CLI-driven workflow** → name it `pki-lifecycle-demo`

### 2. Authenticate and initialize

```bash
terraform login            # opens browser — log in to HCP TF
cd pki-lifecycle-demo/terraform
terraform init             # downloads providers, connects to workspace
```

### 3. Set workspace variables in HCP Terraform UI

**HCP TF UI → Workspace → Variables → + Add variable**

#### Terraform Variables

| Variable | Value | Sensitive? |
|----------|-------|-----------|
| `vault_token` | Your HCP Vault admin token | ✅ **Yes** |
| `vault_addr` | `https://vault-demo-cluster-public-vault-b71960ee.491753e4.z1.hashicorp.cloud:8200` | No (has default) |
| `vault_namespace` | `admin` | No (has default) |
| `region` | `us-east-1` | No |
| `key_name` | Your EC2 key pair name | No |
| `environment` | `demo` | No |

#### Environment Variables (AWS)

| Variable | Sensitive? |
|----------|-----------|
| `AWS_ACCESS_KEY_ID` | ✅ Yes |
| `AWS_SECRET_ACCESS_KEY` | ✅ Yes |
| `AWS_SESSION_TOKEN` | ✅ Yes (if using SSO/STS) |

### 4. Deploy

```bash
terraform plan    # runs remotely in HCP TF — review the output
terraform apply   # ~7 minutes total
```

### 5. Get demo URLs

```bash
terraform output demo_urls
```

---

## Demo Flow (30 Minutes)

### ⏱ 0:00–5:00 — Vault PKI Setup

Open the **Vault UI** → `https://vault-demo-cluster-public-vault-b71960ee.491753e4.z1.hashicorp.cloud:8200/ui`
Log in with namespace `admin`.

1. **Secrets → `pki/`** — show Root CA cert, 10-year validity
2. **Secrets → `pki_int/`** — show Intermediate CA + Certificates tab (certs already issued)
3. **CLI** — issue a cert on-demand to show it's live:

```bash
export VAULT_ADDR="https://vault-demo-cluster-public-vault-b71960ee.491753e4.z1.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
export VAULT_TOKEN="<your token>"

vault write pki_int/issue/apache-role \
  common_name="test.demo.internal" \
  ttl="1h"
```

**Talking point:** _"Vault generates a fresh, short-lived certificate on every request. No more 5-year wildcard certs floating around your infrastructure."_

---

### ⏱ 5:00–13:00 — Apache / Linux Demo

```bash
# SSH in (or use SSM)
aws ssm start-session --target <apache_instance_id>

# Check Vault Agent is running
systemctl status vault-agent

# Show the cert that was automatically issued
openssl x509 -in /etc/vault-agent/certs/cert.pem -noout -subject -issuer -dates

# Verify cert chain
openssl verify -CAfile /etc/vault-agent/certs/chain.pem \
               /etc/vault-agent/certs/cert.pem

# Test HTTPS locally
curl -k https://localhost
```

**Show in browser:** `https://<apache_public_ip>` → demo page loads with Vault CA cert in padlock

**Vault Agent logs:**
```bash
journalctl -u vault-agent -f
```

**Talking point:** _"Vault Agent is running as a systemd service. When the cert approaches expiry, Agent automatically requests a new cert from Vault and reloads Apache — zero downtime, zero operator involvement."_

---

### ⏱ 13:00–21:00 — IIS / Windows Demo

**Option A — SSM (no RDP needed):**
```bash
aws ssm start-session --target <iis_instance_id>
```

**Option B — RDP:** Connect to `<iis_public_ip>:3389`

**In PowerShell:**
```powershell
# Check Vault Agent service
Get-Service VaultAgent

# Show cert in Windows Certificate Store
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Thumbprint, NotAfter

# View bootstrap log
Get-Content C:\Vault\logs\bootstrap.log -Tail 30

# View bind-cert log
Get-Content C:\Vault\logs\bind-cert.log -Tail 20
```

**In IIS Manager:**
1. Sites → Default Web Site → **Bindings** → show HTTPS on 443
2. Click the cert → show it was issued by **Vault Demo Intermediate CA**

**Show in browser:** `https://<iis_public_ip>` → demo page

**Talking point:** _"Same Vault PKI engine, same policy — but now we're talking to the Windows Certificate Store and IIS natively, with no manual cert files or MMC snap-ins."_

---

### ⏱ 21:00–27:00 — Certificate Rotation (Live)

Force a renewal to show the automation:

```bash
# Linux: restart the agent to trigger immediate re-render
ssh ec2-user@<apache_public_ip>
sudo systemctl restart vault-agent
sleep 10
openssl x509 -in /etc/vault-agent/certs/cert.pem -noout -dates
```

**Vault UI → `pki_int/` → Certificates** — show 2+ certs listed (original + renewal)

**Enable audit logging for the compliance story:**
```bash
vault audit enable file file_path=/tmp/vault-audit.log
vault write pki_int/issue/apache-role common_name="audit-demo.internal" ttl="1h"
cat /tmp/vault-audit.log | python3 -m json.tool | head -50
```

**Talking point:** _"Every certificate request is logged in Vault's audit trail — who requested it, when, with what TTL. That's your compliance report right there."_

---

### ⏱ 27:00–30:00 — Wrap-up

| Customer Pain Point | Vault Solution |
|--------------------|----------------|
| 5-year wildcard certs everywhere | Short-lived certs (hours/days) with auto-renewal |
| Manual CSR → CA → install process | Fully automated via Vault Agent |
| No visibility into expiration | Vault UI shows every cert's expiry date |
| Different CAs per team/app | Single internal CA, policy-controlled |
| Compliance audit burden | Complete audit trail for every cert request |

---

## Teardown

```bash
terraform destroy
```

---

## Troubleshooting

### Vault Agent not starting (Linux)
```bash
journalctl -u vault-agent -f
# Test connectivity manually
curl -s $VAULT_ADDR/v1/sys/health | python3 -m json.tool
```

### Cert not rendering (Linux)
```bash
# Manually test AppRole login
vault write auth/approle/login \
  role_id=$(cat /etc/vault-agent/role_id) \
  secret_id=$(cat /etc/vault-agent/secret_id)

# Manually issue a cert
vault write pki_int/issue/apache-role \
  common_name="apache.demo.internal" ttl="1h"
```

### IIS / Windows — Vault Agent service not running
```powershell
Get-Service VaultAgent
Get-Content C:\Vault\logs\bootstrap.log -Tail 50
Start-Service VaultAgent
```

### HCP Vault namespace errors (403)
Verify the `vault_namespace = "admin"` is set in:
- The HCP TF workspace Terraform Variable
- The Vault Agent HCL (`namespace = "admin"` inside the `vault {}` block)

---

## File Reference

```
pki-lifecycle-demo/
├── .gitignore
├── README.md
├── configs/
│   ├── pki-policy-iis.hcl        # Vault policy for IIS agent
│   └── pki-policy-apache.hcl     # Vault policy for Apache agent
└── terraform/
    ├── main.tf                    # AWS infra (EC2, SGs, IAM/SSM) + HCP TF cloud block
    ├── vault.tf                   # All Vault resources (PKI, AppRole, policies)
    ├── variables.tf               # Variables (HCP Vault URL + namespace pre-filled)
    ├── outputs.tf                 # IPs, DNS, instance IDs, CA certs, demo URLs
    ├── terraform.tfvars           # HCP TF workspace variable reference guide
    └── templates/
        ├── windows_userdata.ps1.tpl   # IIS bootstrap (PowerShell)
        └── linux_userdata.sh.tpl      # Apache bootstrap (bash)
```

---

## Resources

- [Vault PKI Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/pki)
- [Vault Agent](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent)
- [Vault Terraform Provider — PKI](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_cert)
- [PKI Engine Tutorial](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine)
- [HCP Vault Namespaces](https://developer.hashicorp.com/vault/docs/enterprise/namespaces)
