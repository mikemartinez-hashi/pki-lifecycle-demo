variable "TFC_VAULT_ADDR" {
  type        = string
  description = "HCP Vault cluster public URL"
  default     = "https://vault-demo-cluster-public-vault-b71960ee.491753e4.z1.hashicorp.cloud:8200"
}

# variable "TFC_VAULT_RUN_ROLE" {
#   type        = string
#   description = "Vault Run Role"
#   # sensitive   = true
# }

variable "TFC_VAULT_NAMESPACE" {
  type        = string
  description = "Vault namespace (HCP Vault uses 'admin' by default)"
  default     = "admin"
}

variable "region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-1"
}

variable "instance_type_windows" {
  type        = string
  description = "EC2 instance type for the Windows/IIS server"
  default     = "t3.medium"
}

variable "instance_type_linux" {
  type        = string
  description = "EC2 instance type for the Linux/Apache server"
  default     = "t3.small"
}

variable "key_name" {
  type        = string
  description = "Name of an existing EC2 key pair (for RDP/SSH fallback access)"
  default     = "windows-demo-kp"
}

variable "environment" {
  type        = string
  description = "Environment tag"
  default     = "demo"
}

variable "owner" {
  type        = string
  description = "Owner tag"
  default     = "SE Team"
}

variable "pki_root_cn" {
  type        = string
  description = "Common Name for the Vault Root CA"
  default     = "Vault Demo Root CA"
}

variable "pki_int_cn" {
  type        = string
  description = "Common Name for the Vault Intermediate CA"
  default     = "Vault Demo Intermediate CA"
}

variable "cert_ttl" {
  type        = string
  description = "Default TTL for issued certificates (e.g. 720h = 30 days)"
  default     = "720h"
}

variable "cert_domain_windows" {
  type        = string
  description = "Common name for the IIS server certificate"
  default     = "iis.demo.internal"
}

variable "cert_domain_linux" {
  type        = string
  description = "Common name for the Apache server certificate"
  default     = "apache.demo.internal"
}
