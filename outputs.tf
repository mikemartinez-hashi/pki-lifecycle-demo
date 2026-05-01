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

output "iis_approle_role_id" {
  description = "AppRole Role ID for IIS Vault Agent (echoed back from workspace variable)"
  value       = var.iis_role_id
}

output "apache_approle_role_id" {
  description = "AppRole Role ID for Apache Vault Agent (echoed back from workspace variable)"
  value       = var.apache_role_id
}

output "demo_urls" {
  description = "Quick-access URLs for the demo"
  value = {
    iis_https    = "https://${aws_instance.iis_server.public_ip}"
    apache_https = "https://${aws_instance.apache_server.public_ip}"
    vault_ui     = "${var.TFC_VAULT_ADDR}/ui"
  }
}
