# openvpn.tf — PRIVATE MANAGEMENT PATH (tutor addendum #2)
#
# Two pieces:
#   1. OpenVPN Access Server (AWS Marketplace, free for 2 concurrent
#      connections) as a small Linux EC2 INSIDE the VPC. A client (Elena's
#      laptop, or a GCP Ubuntu VM) tunnels in over an encrypted channel and
#      receives a private IP — administration and verification of AWS
#      resources then happen as if you were INSIDE the network ("cloud
#      security and networking applied together").
#   2. An S3 Gateway endpoint: traffic to S3 from inside the VPC — including
#      VPN clients — takes the AWS private network, never the public
#      internet. Free of charge. This is the private AWS↔Google storage
#      verification path: the GCP VM fetches S3 backup data through the t
#      unnel + endpoint.
#
# GATED like google_backup.tf: everything deploys ONLY when
# openvpn_enabled = true in terraform.tfvars. The S3 endpoint is ALWAYS on
# (costs nothing, protects data paths).

variable "openvpn_enabled" {
  description = "Deploy the OpenVPN management instance (tutor addendum #2)"
  type        = bool
  default     = false
}

variable "openvpn_ami_id" {
  description = "OpenVPN Access Server AMI (Marketplace BYOL) for ap-southeast-2"
  type        = string
  default     = ""
}

variable "openvpn_instance_type" {
  description = "Instance size for OpenVPN Access Server"
  type        = string
  default     = "t3.micro"
}

variable "openvpn_key_name" {
  description = "EC2 key pair name for SSH administration"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- S3 endpoint
# Endpoint policy = least privilege: read-only on the two project buckets.
# (If a bucket policy ever blocks the endpoint, extend it with an
# aws:SourceVpce condition naming this endpoint — one-line fix.)

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-southeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PrivateReadProjectBuckets"
        Effect   = "Allow"
        Principal = "*"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::sunsip-cloud-artifacts-311141538922",
          "arn:aws:s3:::sunsip-cloud-artifacts-311141538922/*",
          "arn:aws:s3:::sunsip-cloud-site-311141538922",
          "arn:aws:s3:::sunsip-cloud-site-311141538922/*",
        ]
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-s3-gateway" })
}

# ------------------------------------------------------------ OpenVPN instance
resource "aws_security_group" "openvpn" {
  count       = var.openvpn_enabled ? 1 : 0
  name        = "${var.project_name}-openvpn-sg"
  description = "OpenVPN Access Server: web UI 943, tunnel 1194/udp, HTTPS, SSH admin"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Access Server web UI / client portal"
    from_port   = 943
    to_port     = 943
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (portal + admin redirect)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "OpenVPN tunnel"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH administration (lab: from anywhere; restrict in prod)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Everything out"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-openvpn-sg" })
}

resource "aws_instance" "openvpn" {
  count                  = var.openvpn_enabled ? 1 : 0
  ami                    = var.openvpn_ami_id
  instance_type          = var.openvpn_instance_type
  key_name               = var.openvpn_key_name != "" ? var.openvpn_key_name : null
  subnet_id              = aws_subnet.city_experience[0].id
  vpc_security_group_ids = [aws_security_group.openvpn[0].id]

  # Marketplace AMI already contains Access Server; first boot = set the
  # admin password over SSH on camera (the Linux-administration beat).
  user_data = <<-EOF
    #!/bin/bash
    apt-get -y update
  EOF

  tags = merge(local.common_tags, { Name = "${var.project_name}-openvpn-mgmt" })

  depends_on = [aws_internet_gateway.main]
}

output "openvpn_public_ip" {
  description = "Public address of the OpenVPN server (portal + tunnel)"
  value       = var.openvpn_enabled ? aws_instance.openvpn[0].public_ip : ""
}

output "openvpn_private_ip" {
  description = "Private VPC address — the tunnelled ping target"
  value       = var.openvpn_enabled ? aws_instance.openvpn[0].private_ip : ""
}

output "s3_gateway_endpoint_id" {
  description = "The S3 Gateway endpoint id (private route proof)"
  value       = aws_vpc_endpoint.s3_gateway.id
}
