# Bootstrap layer — creates the two PERMANENT Terraform state resources:
#   1. S3 bucket that stores the MAIN config's remote state
#   2. DynamoDB table that locks that state during applies
#
# This bootstrap config keeps its OWN state locally (no backend block) —
# the terraform.tfstate file it produces is the brief's evidence that local
# state was created during execution. The main infra/ config then uses the
# S3 backend created here. Apply this ONCE; these resources persist between
# work sessions (costs pennies/month, mostly free tier).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region              = "ap-southeast-2"
  profile             = "terraform-sunsip"
  allowed_account_ids = ["311141538922"] # hard guard: never deploy elsewhere
}

# ---------------------------------------------------------------- state bucket

resource "aws_s3_bucket" "tfstate" {
  bucket = "sunsip-cloud-tfstate-311141538922"

  tags = {
    Project     = "sunsip-cloud"
    Purpose     = "terraform-state"
    ManagedBy   = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------- state lock table

resource "aws_dynamodb_table" "tf_locks" {
  name         = "sunsip-cloud-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project = "sunsip-cloud"
    Purpose = "terraform-state-locking"
  }
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.tf_locks.name
}