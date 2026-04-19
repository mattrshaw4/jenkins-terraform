# ============================================================
# PROVIDER
# Tells Terraform to use AWS and which region to deploy into
# ============================================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ============================================================
# DATA SOURCE — Default VPC
# Looks up your existing Default VPC instead of creating one
# ============================================================
data "aws_vpc" "default" {
  default = true
}

# ============================================================
# DATA SOURCE — Latest Amazon Linux 2023 AMI
# Finds the current AL2023 AMI automatically — no hardcoded ID
# ============================================================
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================
# SECURITY GROUP
# Port 22  — SSH from your IP only
# Port 8080 — Jenkins UI open to the world
# All outbound traffic allowed (required for Jenkins to download plugins)
# ============================================================
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-security-group"
  description = "Allow SSH from my IP and Jenkins UI on 8080"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["174.95.4.138/32", "18.206.107.24/29"]
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jenkins-security-group"
  }
}

# ============================================================
# EC2 INSTANCE — Jenkins Server
# Amazon Linux 2023 AMI (us-east-1)
# t2.micro — free tier eligible
# user_data bootstraps Jenkins on first boot
# ============================================================
resource "aws_instance" "jenkins_server" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t2.micro"
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = <<-USERDATA
    #!/bin/bash

    # Log all output for debugging
    exec > /var/log/user-data.log 2>&1

    echo "=== Starting user_data script ==="

    # Update system packages
    dnf update -y
    echo "=== dnf update complete ==="

    # Install Java 21
    dnf install -y java-21-amazon-corretto
    echo "=== Java 21 installed ==="

    # Import Jenkins GPG key
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
    echo "=== GPG key imported ==="

    # Write Jenkins repo file using printf — avoids nested heredoc issues
    printf '[jenkins]\nname=Jenkins-stable\nbaseurl=https://pkg.jenkins.io/redhat-stable\ngpgcheck=0\nenabled=1\n' > /etc/yum.repos.d/jenkins.repo
    echo "=== Repo file written ==="

    # Refresh dnf cache
    dnf clean all
    dnf makecache
    echo "=== dnf cache refreshed ==="

    # Install Jenkins
    dnf install -y jenkins
    echo "=== Jenkins installed ==="

    # Enable and start Jenkins
    systemctl enable jenkins
    systemctl start jenkins
    echo "=== Jenkins started ==="
  USERDATA
    



  tags = {
    Name = "jenkins-server"
  }
}

# ============================================================
# S3 BUCKET — Jenkins Artifacts
# Private bucket — public access explicitly blocked
# ============================================================
resource "aws_s3_bucket" "jenkins_artifacts" {
  bucket = "jenkins-artifacts-shawr-2025"

  tags = {
    Name    = "jenkins-artifacts"
    Purpose = "Jenkins CI/CD artifact storage"
  }
}

resource "aws_s3_bucket_public_access_block" "jenkins_artifacts_block" {
  bucket = aws_s3_bucket.jenkins_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# OUTPUTS
# Printed after terraform apply — values you'll need
# ============================================================
output "jenkins_public_ip" {
  description = "Public IP of the Jenkins server"
  value       = aws_instance.jenkins_server.public_ip
}

output "jenkins_url" {
  description = "Jenkins UI URL"
  value       = "http://${aws_instance.jenkins_server.public_ip}:8080"
}

output "s3_bucket_name" {
  description = "Jenkins artifacts S3 bucket name"
  value       = aws_s3_bucket.jenkins_artifacts.bucket
}
