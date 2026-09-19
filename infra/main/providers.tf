# SunSip Cloud — main Terraform configuration.
#
# State lives REMOTELY in the S3 bucket created by infra/bootstrap
# (versioned + encrypted), with locking in DynamoDB — brief section F.
# The bootstrap's local terraform.tfstate is the evidence that local state
# was created during execution; this backend block is the remote-state
# requirement. Both documented in the report.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "sunsip-cloud-tfstate-311141538922"
    key            = "sunsip-cloud/main.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "sunsip-cloud-tf-locks"
    profile        = "terraform-sunsip"
    encrypt        = true
  }
}

provider "aws" {
  region              = var.aws_region
  profile             = "terraform-sunsip"
  allowed_account_ids = ["311141538922"]
}

# Default tags applied to every resource — tidy console, easy cost filtering.
locals {
  common_tags = {
    Project     = "sunsip-cloud"
    Environment = "assessment"
    ManagedBy   = "terraform"
  }
}