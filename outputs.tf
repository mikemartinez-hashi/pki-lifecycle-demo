output "iis_server_public_ip" {
  description = "Public IP of the Windows/IIS server"
  value       = aws_instance.iis_server.public_ip
}

output "iis_server_public_dns" {
  description = "Public DNS of the Windows/IIS server"
  value       = aws_instance.iis_server.public_dns
}

output "iis_server_instance_id" {
  description = "Instance ID — use with SSM Session Manager to avoid RDP"
  value       = aws_instance.iis_server.id
}

output "apache_server_public_ip" {
  description = "Public IP of the Linux/Apache server"
  value       = aws_instance.apache_server.public_ip
}

output "apache_server_public_dns" {
  description = "Public DNS of the Linux/Apache server"
  value       = aws_instance.apache_server.public_dns
}

output "apache_server_instance_id" {
  description = "Instance ID — use with SSM Session Manager"
  value       = aws_instance.apache_server.id
}

output "vault_pki_root_ca_cert" {
  description = "Root CA certificate PEM — import into browser trust store to avoid TLS warnings during demo"
  value       = vault_pki_secret_backend_root_cert.root_ca.certificate
  sensitive   = false
}

output "vault_pki_int_ca_cert" {
  description = "Intermediate CA certificate PEM"
  value       = vault_pki_secret_backend_root_sign_intermediate.int_signed.certificate
  sensitive   = false
}

output "iis_approle_role_id" {
  description = "AppRole Role ID for IIS Vault Agent"
  value       = vault_approle_auth_backend_role.iis.role_id
}

output "apache_approle_role_id" {
  description = "AppRole Role ID for Apache Vault Agent"
  value       = vault_approle_auth_backend_role.apache.role_id
}

output "demo_urls" {
  description = "Quick-access URLs for the demo"
  value = {
    iis_https    = "https://${aws_instance.iis_server.public_ip}"
    apache_https = "https://${aws_instance.apache_server.public_ip}"
    vault_ui     = "${var.vault_addr}/ui"
  }
}
