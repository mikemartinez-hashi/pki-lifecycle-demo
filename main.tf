terraform {
  required_version = ">= 1.5"

  # ── HCP Terraform (remote execution) ──────────────────────────────────────
  # NOTE: The cloud{} block does NOT support variables — values must be literals.
  # Replace YOUR_HCP_TF_ORG with your actual organization name.
  # Create the workspace in HCP TF UI first: New Workspace → CLI-driven → "pki-lifecycle-demo"
  # cloud {
  #   organization = "YOUR_HCP_TF_ORG"   # ← replace with your org (e.g. "hashicorp-se-demos")
  #   workspaces {
  #     name = "pki-lifecycle-demo"
  #   }
  # }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# ─── Providers ────────────────────────────────────────────────────────────────

provider "aws" {
  region = var.region
  # AWS credentials are set as Environment Variables in the HCP TF workspace:
  # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (and optionally AWS_SESSION_TOKEN)
}

provider "vault" {
  # address   = var.TFC_VAULT_ADDR
  # namespace = var.TFC_VAULT_NAMESPACE
}

# ─── AMIs ─────────────────────────────────────────────────────────────────────

# Same filter/owner as tf-demo-hashi-windows reference repo
data "aws_ami" "hc_base_windows" {
  filter {
    name   = "name"
    values = ["hc-base-windows-server-2025*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}

# Get AMI ID
data "aws_ami" "hc-base-ubuntu" {
  for_each = toset(["amd64", "arm64"])
  filter {
    name   = "name"
    values = [format("hc-base-ubuntu-2404-%s-*", each.value)]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}

# ─── Security Groups ──────────────────────────────────────────────────────────

resource "aws_security_group" "pki_demo_windows" {
  name        = "pki-demo-windows-${var.environment}"
  description = "PKI Demo - Windows/IIS server"

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RDP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "pki-demo-windows-sg-${var.environment}"
    Environment = var.environment
    Owner       = var.owner
  }
}

resource "aws_security_group" "pki_demo_linux" {
  name        = "pki-demo-linux-${var.environment}"
  description = "PKI Demo - Linux/Apache server"

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "pki-demo-linux-sg-${var.environment}"
    Environment = var.environment
    Owner       = var.owner
  }
}

# ─── IAM / SSM ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ssm_role" {
  name = "pki-demo-ssm-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "pki-demo-ssm-profile-${var.environment}"
  role = aws_iam_role.ssm_role.name
}

# ─── EC2: Windows / IIS ───────────────────────────────────────────────────────

resource "aws_instance" "iis_server" {
  ami           = data.aws_ami.hc_base_windows.id
  instance_type = var.instance_type_windows
  key_name      = var.key_name

  security_groups      = [aws_security_group.pki_demo_windows.name]
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  # Ensure Vault PKI + AppRole are fully configured before the instance boots
  depends_on = [
    vault_pki_secret_backend_role.iis_role,
    vault_approle_auth_backend_role_secret_id.iis_secret_id,
  ]

  user_data = templatefile("${path.module}/templates/windows_userdata.ps1.tpl", {
    vault_addr      = var.TFC_VAULT_ADDR
    vault_namespace = var.TFC_VAULT_NAMESPACE
    role_id         = vault_approle_auth_backend_role.iis.role_id
    secret_id       = vault_approle_auth_backend_role_secret_id.iis_secret_id.secret_id
    common_name     = var.cert_domain_windows
    cert_ttl        = var.cert_ttl
  })

  tags = {
    Name        = "pki-demo-iis-${var.environment}"
    Type        = "PKI Demo - IIS"
    Environment = var.environment
    Owner       = var.owner
  }
}

# ─── EC2: Linux / Apache ──────────────────────────────────────────────────────

resource "aws_instance" "apache_server" {
  ami           = data.aws_ami.hc_base_ubuntu[amd64].id
  instance_type = var.instance_type_linux
  key_name      = var.key_name

  security_groups      = [aws_security_group.pki_demo_linux.name]
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  depends_on = [
    vault_pki_secret_backend_role.apache_role,
    vault_approle_auth_backend_role_secret_id.apache_secret_id,
  ]

  user_data = templatefile("${path.module}/templates/linux_userdata.sh.tpl", {
    vault_addr      = var.TFC_VAULT_ADDR
    vault_namespace = var.TFC_VAULT_NAMESPACE
    role_id         = vault_approle_auth_backend_role.apache.role_id
    secret_id       = vault_approle_auth_backend_role_secret_id.apache_secret_id.secret_id
    common_name     = var.cert_domain_linux
    cert_ttl        = var.cert_ttl
  })

  tags = {
    Name        = "pki-demo-apache-${var.environment}"
    Type        = "PKI Demo - Apache"
    Environment = var.environment
    Owner       = var.owner
  }
}
