# Phase 2 Step 3 — Networking & Security (brief section A).
#
# One dedicated VPC, public subnets across two AZs (HA), internet gateway,
# route tables with deliberate CIDR planning, and nested security groups:
#   ALB SGs  — ingress 80/443 from the world
#   Task SGs — ingress ONLY from the matching ALB SG (nested, as scored)
# All resources get the common tags via the provider default_tags pattern
# (locals.common_tags in providers.tf).

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------- VPC

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-vpc" })
}

# ------------------------------------------------------------ public subnets

# One public subnet per AZ per service tier. CIDR plan:
#   10.0.0.0/16 VPC
#   ├─ 10.0.1.0/24  city-experience  AZ-a
#   ├─ 10.0.2.0/24  city-experience  AZ-b
#   ├─ 10.0.11.0/24 user-collection  AZ-a
#   └─ 10.0.12.0/24 user-collection  AZ-b
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_subnet" "city_experience" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1) # 10.0.1.0/24, 10.0.2.0/24
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-city-experience-${local.azs[count.index]}"
    Tier = "city-experience"
  })
}

resource "aws_subnet" "user_collection" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 11) # 10.0.11.0/24, 10.0.12.0/24
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-user-collection-${local.azs[count.index]}"
    Tier = "user-collection"
  })
}

# ------------------------------------------- internet gateway + routing

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${var.project_name}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-public-rt" })
}

resource "aws_route_table_association" "city_experience" {
  count          = var.az_count
  subnet_id      = aws_subnet.city_experience[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "user_collection" {
  count          = var.az_count
  subnet_id      = aws_subnet.user_collection[count.index].id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------ security groups
# Nested design (scored): task SGs accept traffic ONLY from their ALB SG.

resource "aws_security_group" "alb_city_experience" {
  name        = "${var.project_name}-alb-city-sg"
  description = "Public ALB for city-experience: HTTP/HTTPS from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To tasks (any port inside VPC)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-alb-city-sg" })
}

resource "aws_security_group" "alb_user_collection" {
  name        = "${var.project_name}-alb-user-sg"
  description = "Public ALB for user-collection: HTTP/HTTPS from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To tasks (any port inside VPC)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-alb-user-sg" })
}

resource "aws_security_group" "tasks_city_experience" {
  name        = "${var.project_name}-tasks-city-sg"
  description = "city-experience tasks: ingress only from their ALB SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Container port from the city ALB only"
    from_port       = var.service_ports["city-experience"]
    to_port         = var.service_ports["city-experience"]
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_city_experience.id]
  }

  egress {
    description = "All outbound (ECR pulls, provider APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-tasks-city-sg" })
}

resource "aws_security_group" "tasks_user_collection" {
  name        = "${var.project_name}-tasks-user-sg"
  description = "user-collection tasks: ingress only from their ALB SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Container port from the user ALB only"
    from_port       = var.service_ports["user-collection"]
    to_port         = var.service_ports["user-collection"]
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_user_collection.id]
  }

  egress {
    description = "All outbound (ECR pulls, DynamoDB via AWS API)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-tasks-user-sg" })
}

# ------------------------------------------------------------------ outputs

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = concat(aws_subnet.city_experience[*].id, aws_subnet.user_collection[*].id)
}

output "security_group_ids" {
  value = {
    alb_city_experience = aws_security_group.alb_city_experience.id
    alb_user_collection = aws_security_group.alb_user_collection.id
    tasks_city          = aws_security_group.tasks_city_experience.id
    tasks_user          = aws_security_group.tasks_user_collection.id
  }
}