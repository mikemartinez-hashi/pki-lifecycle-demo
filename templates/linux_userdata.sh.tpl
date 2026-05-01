#!/usr/bin/env bash
# ============================================================
# Vault PKI Demo — Linux/Apache Vault Agent Bootstrap
# Injected by Terraform templatefile()
# ============================================================
set -euo pipefail

# ── Variables injected by Terraform ─────────────────────────
VAULT_ADDR="${vault_addr}"
VAULT_NAMESPACE="${vault_namespace}"
ROLE_ID="${role_id}"
SECRET_ID="${secret_id}"
COMMON_NAME="${common_name}"
CERT_TTL="${cert_ttl}"

# ── Paths ────────────────────────────────────────────────────
VAULT_DIR="/etc/vault-agent"
CERT_DIR="/etc/vault-agent/certs"
LOG_FILE="/var/log/vault-agent-bootstrap.log"
VAULT_BIN="/usr/local/bin/vault"
VAULT_VER="1.17.2"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Vault PKI Bootstrap started at $(date) ==="

# ── 1. Install Apache + dependencies ─────────────────────────
echo ">>> Installing Apache and dependencies..."
dnf update -y -q
dnf install -y -q httpd mod_ssl openssl unzip

systemctl enable httpd
systemctl start httpd

# ── 2. Create demo web page ──────────────────────────────────
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html>
<html>
<head>
  <title>Vault PKI Demo - Apache</title>
  <style>
    body { font-family: sans-serif; background: #0d1117; color: #e6edf3;
           display: flex; align-items: center; justify-content: center;
           height: 100vh; margin: 0; }
    .card { background: #161b22; padding: 2rem 3rem; border-radius: 12px;
            border: 1px solid #30363d; text-align: center; max-width: 500px; }
    h1 { color: #58a6ff; }
    span { color: #3fb950; font-family: monospace; }
  </style>
</head>
<body>
  <div class="card">
    <h1>🔐 Vault PKI Demo</h1>
    <h2>Apache — Amazon Linux 2023</h2>
    <p>Certificate issued by: <span>Vault Intermediate CA</span></p>
    <p>Provisioned automatically by <span>Vault Agent</span></p>
    <p>Renewal is <span>fully automated</span> — zero human interaction</p>
  </div>
</body>
</html>
HTML
echo ">>> Demo page created."

# ── 3. Download and install Vault binary ─────────────────────
echo ">>> Downloading Vault $VAULT_VER..."
curl -fsSLo /tmp/vault.zip \
  "https://releases.hashicorp.com/vault/$${VAULT_VER}/vault_$${VAULT_VER}_linux_amd64.zip"
unzip -o /tmp/vault.zip -d /usr/local/bin/
chmod +x $VAULT_BIN
rm /tmp/vault.zip
echo ">>> Vault installed at $VAULT_BIN"

# ── 4. Create directories and write AppRole credentials ──────
mkdir -p "$VAULT_DIR" "$CERT_DIR"
chmod 700 "$VAULT_DIR" "$CERT_DIR"

echo -n "$ROLE_ID"   > "$VAULT_DIR/role_id"
echo -n "$SECRET_ID" > "$VAULT_DIR/secret_id"
chmod 600 "$VAULT_DIR/role_id" "$VAULT_DIR/secret_id"
echo ">>> AppRole credentials written."

# ── 5. Write Consul Template files ───────────────────────────

cat > "$VAULT_DIR/cert.tpl" << 'TMPL'
{{ with secret "pki_int/issue/apache-role" "common_name=COMMON_NAME_PLACEHOLDER" "ttl=CERT_TTL_PLACEHOLDER" "alt_names=localhost" }}
{{ .Data.certificate }}
{{ end }}
TMPL

cat > "$VAULT_DIR/key.tpl" << 'TMPL'
{{ with secret "pki_int/issue/apache-role" "common_name=COMMON_NAME_PLACEHOLDER" "ttl=CERT_TTL_PLACEHOLDER" "alt_names=localhost" }}
{{ .Data.private_key }}
{{ end }}
TMPL

cat > "$VAULT_DIR/chain.tpl" << 'TMPL'
{{ with secret "pki_int/issue/apache-role" "common_name=COMMON_NAME_PLACEHOLDER" "ttl=CERT_TTL_PLACEHOLDER" "alt_names=localhost" }}
{{ .Data.issuing_ca }}
{{ end }}
TMPL

# Substitute placeholder values
sed -i "s|COMMON_NAME_PLACEHOLDER|$COMMON_NAME|g" "$VAULT_DIR/cert.tpl" "$VAULT_DIR/key.tpl" "$VAULT_DIR/chain.tpl"
sed -i "s|CERT_TTL_PLACEHOLDER|$CERT_TTL|g"       "$VAULT_DIR/cert.tpl" "$VAULT_DIR/key.tpl" "$VAULT_DIR/chain.tpl"

echo ">>> Consul Template files written."

# ── 6. Write Apache SSL virtual host ─────────────────────────
cat > /etc/httpd/conf.d/vault-ssl.conf << APACHECONF
# Vault PKI Demo — Apache SSL Virtual Host
# Certificate and key are managed by Vault Agent

<VirtualHost *:443>
    ServerName $COMMON_NAME
    ServerAlias localhost

    DocumentRoot /var/www/html
    DirectoryIndex index.html

    SSLEngine             on
    SSLCertificateFile    $CERT_DIR/cert.pem
    SSLCertificateKeyFile $CERT_DIR/key.pem
    SSLCACertificateFile  $CERT_DIR/chain.pem

    SSLProtocol           -All +TLSv1.2 +TLSv1.3
    SSLCipherSuite        HIGH:!aNULL:!MD5

    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog  /var/log/httpd/ssl_error.log
    CustomLog /var/log/httpd/ssl_access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName $COMMON_NAME
    Redirect permanent / https://$COMMON_NAME/
</VirtualHost>
APACHECONF

echo ">>> Apache SSL vhost written."

# ── 7. Write Vault Agent HCL ─────────────────────────────────
cat > "$VAULT_DIR/vault-agent.hcl" << AGENTCFG
# Vault Agent Configuration — Apache PKI Demo
# Manages certificate lifecycle via AppRole + HCP Vault

vault {
  address   = "$VAULT_ADDR"
  namespace = "$VAULT_NAMESPACE"
  retry {
    num_retries = 10
  }
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                = "$VAULT_DIR/role_id"
      secret_id_file_path              = "$VAULT_DIR/secret_id"
      remove_secret_id_file_after_read = false
    }
  }
  sink "file" {
    config = {
      path = "$VAULT_DIR/vault-token"
    }
  }
}

template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = false
}

# Certificate — triggers Apache reload after render
template {
  source      = "$VAULT_DIR/cert.tpl"
  destination = "$CERT_DIR/cert.pem"
  perms       = 0644
  exec {
    command = ["systemctl", "reload", "httpd"]
    timeout = "30s"
  }
}

template {
  source      = "$VAULT_DIR/key.tpl"
  destination = "$CERT_DIR/key.pem"
  perms       = 0600
}

template {
  source      = "$VAULT_DIR/chain.tpl"
  destination = "$CERT_DIR/chain.pem"
  perms       = 0644
}
AGENTCFG

echo ">>> Vault Agent HCL written."

# ── 8. Create vault-agent systemd service ────────────────────
cat > /etc/systemd/system/vault-agent.service << 'SYSTEMD'
[Unit]
Description=HashiCorp Vault Agent — PKI Certificate Manager
Documentation=https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/vault-agent.hcl
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vault-agent

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable vault-agent
echo ">>> vault-agent systemd service created."

# ── 9. Start Vault Agent ─────────────────────────────────────
echo ">>> Starting Vault Agent..."
systemctl start vault-agent

# Allow time to authenticate and render certs
sleep 15

# ── 10. Verify cert and reload Apache ────────────────────────
if [ -f "$CERT_DIR/cert.pem" ]; then
    echo ">>> Certificate rendered successfully:"
    openssl x509 -in "$CERT_DIR/cert.pem" -noout -subject -issuer -dates
    systemctl reload httpd
    echo ">>> Apache reloaded with Vault-issued certificate."
else
    echo ">>> WARNING: cert.pem not yet rendered — agent may still be initializing."
    echo ">>> Run: journalctl -u vault-agent -f"
fi

echo "=== Bootstrap complete at $(date) ==="
