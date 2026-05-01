<powershell>
# ============================================================
# Vault PKI Demo — Windows/IIS Vault Agent Bootstrap
# Injected by Terraform templatefile()
# ============================================================
Set-ExecutionPolicy Bypass -Scope Process -Force
$ErrorActionPreference = "Stop"

# ── Variables injected by Terraform ─────────────────────────
$VAULT_ADDR      = "${vault_addr}"
$VAULT_NAMESPACE = "${vault_namespace}"
$ROLE_ID         = "${role_id}"
$SECRET_ID       = "${secret_id}"
$COMMON_NAME     = "${common_name}"
$CERT_TTL        = "${cert_ttl}"

# ── Paths ────────────────────────────────────────────────────
$VAULT_DIR   = "C:\Vault"
$CERT_DIR    = "C:\Vault\certs"
$LOG_DIR     = "C:\Vault\logs"
$VAULT_BIN   = "$VAULT_DIR\vault.exe"
$AGENT_CFG   = "$VAULT_DIR\vault-agent.hcl"
$CERT_TMPL   = "$VAULT_DIR\cert.tpl"
$KEY_TMPL    = "$VAULT_DIR\key.tpl"
$CHAIN_TMPL  = "$VAULT_DIR\chain.tpl"
$BIND_SCRIPT = "$VAULT_DIR\bind-cert.ps1"

# ── Logging helper ───────────────────────────────────────────
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $msg" | Tee-Object -FilePath "$LOG_DIR\bootstrap.log" -Append
}

# ── 1. Create directories ────────────────────────────────────
New-Item -ItemType Directory -Force -Path $VAULT_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $CERT_DIR  | Out-Null
New-Item -ItemType Directory -Force -Path $LOG_DIR   | Out-Null
Log "Directories created."

# ── 2. Install IIS + management tools ───────────────────────
Log "Installing IIS..."
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Net-Ext45 -IncludeManagementTools | Out-Null

Remove-Item "C:\inetpub\wwwroot\iisstart.htm" -Force -ErrorAction SilentlyContinue

@"
<!DOCTYPE html>
<html>
<head><title>Vault PKI Demo - IIS</title>
<style>
  body { font-family: sans-serif; background: #1a1a2e; color: #eee;
         display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .card { background: #16213e; padding: 2rem 3rem; border-radius: 12px;
          border: 1px solid #0f3460; text-align: center; }
  h1 { color: #e94560; } span { color: #53d8fb; font-family: monospace; }
</style></head>
<body><div class="card">
  <h1>🔐 Vault PKI Demo</h1>
  <h2>IIS — Windows Server 2025</h2>
  <p>Certificate issued by: <span>Vault Intermediate CA</span></p>
  <p>Common Name: <span>$COMMON_NAME</span></p>
  <p>Provisioned automatically by <span>Vault Agent</span></p>
</div></body></html>
"@ | Out-File "C:\inetpub\wwwroot\index.html" -Encoding utf8
Log "IIS installed and demo page created."

# ── 3. Download Vault binary ─────────────────────────────────
Log "Downloading Vault binary..."
$VAULT_VER = "1.17.2"
$VAULT_ZIP = "$VAULT_DIR\vault.zip"
Invoke-WebRequest -Uri "https://releases.hashicorp.com/vault/$VAULT_VER/vault_$($VAULT_VER)_windows_amd64.zip" `
    -OutFile $VAULT_ZIP -UseBasicParsing
Expand-Archive -Path $VAULT_ZIP -DestinationPath $VAULT_DIR -Force
Remove-Item $VAULT_ZIP
Log "Vault $VAULT_VER downloaded."

# ── 4. Write AppRole credentials ─────────────────────────────
$ROLE_ID   | Out-File "$VAULT_DIR\role_id"   -Encoding ascii -NoNewline
$SECRET_ID | Out-File "$VAULT_DIR\secret_id" -Encoding ascii -NoNewline
Log "AppRole credentials written."

# ── 5. Write Consul Template files ──────────────────────────
# cert.tpl
@'
{{ with secret "pki_int/issue/iis-role" "common_name=COMMON_NAME_PLACEHOLDER" "ttl=CERT_TTL_PLACEHOLDER" "alt_names=localhost" }}
{{ .Data.certificate }}
{{ end }}
'@ -replace "COMMON_NAME_PLACEHOLDER", $COMMON_NAME `
   -replace "CERT_TTL_PLACEHOLDER",    $CERT_TTL | Out-File $CERT_TMPL -Encoding ascii

# key.tpl
@'
{{ with secret "pki_int/issue/iis-role" "common_name=COMMON_NAME_PLACEHOLDER" "ttl=CERT_TTL_PLACEHOLDER" "alt_names=localhost" }}
{{ .Data.private_key }}
{{ end }}
'@ -replace "COMMON_NAME_PLACEHOLDER", $COMMON_NAME `
   -replace "CERT_TTL_PLACEHOLDER",    $CERT_TTL | Out-File $KEY_TMPL -Encoding ascii

# chain.tpl
@'
{{ with secret "pki_int/issue/iis-role" "common_name=COMMON_NAME_PLACEHOLDER" "ttl=CERT_TTL_PLACEHOLDER" "alt_names=localhost" }}
{{ .Data.issuing_ca }}
{{ end }}
'@ -replace "COMMON_NAME_PLACEHOLDER", $COMMON_NAME `
   -replace "CERT_TTL_PLACEHOLDER",    $CERT_TTL | Out-File $CHAIN_TMPL -Encoding ascii

Log "Consul Template files written."

# ── 6. Write bind-cert.ps1 (exec hook called by Vault Agent) ─
@'
# bind-cert.ps1 — Triggered by Vault Agent after cert/key are rendered.
# Imports the certificate into Windows Cert Store and binds it to IIS HTTPS.

$ErrorActionPreference = "SilentlyContinue"
$CERT_DIR  = "C:\Vault\certs"
$PFX_FILE  = "$CERT_DIR\cert.pfx"
$PFX_PASS  = "VaultDemo123!"
$LOG       = "C:\Vault\logs\bind-cert.log"

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Tee-Object -FilePath $LOG -Append }

Log "bind-cert.ps1 triggered by Vault Agent."
Start-Sleep -Seconds 3

if (-not (Test-Path "$CERT_DIR\cert.pem") -or -not (Test-Path "$CERT_DIR\key.pem")) {
    Log "ERROR: cert.pem or key.pem not found. Aborting."
    exit 1
}

# Try openssl (available in Git for Windows) to build the PFX
$opensslPath = "C:\Program Files\Git\usr\bin\openssl.exe"
if (Test-Path $opensslPath) {
    & $opensslPath pkcs12 -export -out $PFX_FILE `
        -inkey "$CERT_DIR\key.pem" -in "$CERT_DIR\cert.pem" `
        -certfile "$CERT_DIR\chain.pem" -passout "pass:$PFX_PASS" 2>> $LOG
    Log "PFX created with openssl."
} else {
    & certutil -addstore MY "$CERT_DIR\cert.pem" 2>> $LOG
    Log "Certificate imported via certutil (openssl not found)."
}

# Import PFX into Local Machine\My store
if (Test-Path $PFX_FILE) {
    $SecurePass = ConvertTo-SecureString -String $PFX_PASS -Force -AsPlainText
    $cert = Import-PfxCertificate -FilePath $PFX_FILE `
        -CertStoreLocation Cert:\LocalMachine\My -Password $SecurePass -Exportable
    $thumbprint = $cert.Thumbprint
    Log "PFX imported. Thumbprint: $thumbprint"
} else {
    $cert = Get-ChildItem Cert:\LocalMachine\My | Sort-Object NotBefore -Descending | Select-Object -First 1
    $thumbprint = $cert.Thumbprint
    Log "Using most recent cert. Thumbprint: $thumbprint"
}

# Update IIS HTTPS binding
Import-Module WebAdministration -ErrorAction SilentlyContinue
$site = "Default Web Site"
$existing = Get-WebBinding -Name $site -Protocol https -Port 443 -ErrorAction SilentlyContinue
if ($existing) {
    Remove-WebBinding -Name $site -Protocol https -Port 443
    Log "Removed old HTTPS binding."
}
New-WebBinding -Name $site -Protocol https -Port 443 -IPAddress "*"
$binding = Get-WebBinding -Name $site -Protocol https -Port 443
$binding.AddSslCertificate($thumbprint, "My")
Log "IIS HTTPS binding updated."

Restart-Service W3SVC -Force
Log "IIS restarted. Done."
'@ | Out-File $BIND_SCRIPT -Encoding ascii
Log "bind-cert.ps1 written."

# ── 7. Write Vault Agent HCL config ─────────────────────────
# Build escaped Windows paths once so the HCL is clean
$VaultDirEsc  = $VAULT_DIR.Replace('\', '\\')
$CertDirEsc   = $CERT_DIR.Replace('\',  '\\')
$CertTmplEsc  = $CERT_TMPL.Replace('\', '\\')
$KeyTmplEsc   = $KEY_TMPL.Replace('\',  '\\')
$ChainTmplEsc = $CHAIN_TMPL.Replace('\','\\')
$BindEsc      = $BIND_SCRIPT.Replace('\','\\')

@"
# Vault Agent Configuration — IIS PKI Demo
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
      role_id_file_path                = "$VaultDirEsc\\role_id"
      secret_id_file_path              = "$VaultDirEsc\\secret_id"
      remove_secret_id_file_after_read = false
    }
  }
  sink "file" {
    config = {
      path = "$VaultDirEsc\\vault-token"
    }
  }
}

template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = false
}

template {
  source      = "$CertTmplEsc"
  destination = "$CertDirEsc\\cert.pem"
  exec {
    command = ["powershell.exe", "-File", "$BindEsc"]
    timeout = "60s"
  }
}

template {
  source      = "$KeyTmplEsc"
  destination = "$CertDirEsc\\key.pem"
}

template {
  source      = "$ChainTmplEsc"
  destination = "$CertDirEsc\\chain.pem"
}
"@ | Out-File $AGENT_CFG -Encoding ascii
Log "Vault Agent HCL written."

# ── 8. Register and start Vault Agent as a Windows Service ───
Log "Registering Vault Agent service..."
$svcName = "VaultAgent"

if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $svcName | Out-Null
    Start-Sleep -Seconds 2
}

$binPath = "`"$VAULT_BIN`" agent -config=`"$AGENT_CFG`""
sc.exe create $svcName binPath= $binPath start= auto obj= LocalSystem DisplayName= "Vault Agent (PKI)" | Out-Null
sc.exe description $svcName "HashiCorp Vault Agent - PKI Certificate Manager" | Out-Null
sc.exe failure $svcName reset= 60 actions= restart/5000/restart/10000/restart/30000 | Out-Null
Log "Service registered."

Start-Sleep -Seconds 5
Start-Service -Name $svcName
Log "Vault Agent service started. Bootstrap complete."
</powershell>
