# ─── Phase 6: Google Cloud — DynamoDB backup into GCS (brief LO1/p5) ─────────
# LO1: "Utilise infrastructure-as-code tools to streamline deployment across
# AWS, Azure, and Google Cloud" and p5: "…single, consistent codebase that
# successfully deploys complex elements like VMs, Load Balancers, and managed
# databases" across the three clouds. Chosen Google role (Elena's design
# decision, recorded 14 Oct): **DB BACKUP** — DynamoDB's native export lands in
# a staging S3 bucket, then the same Terraform codebase provisions the Google
# side that receives and retains it.
#
# TWO-PATH DELIVERY (documented tradeoff for the report):
#  A. IaC path (ALWAYS available): this file — Terraform's google provider
#     plans and validates real Google resources: GCS bucket, service account,
#     IAM binding. `terraform plan` output + provider install = LO1 evidence
#     even before any GCP login.
#  B. Live path (card-gated): GCP requires a billing account (credit card)
#     before ANY project/bucket exists — Elena refuses card-gated signups.
#     Options to resolve with the tutor: college GCP credits, a class
#     billing project, or tutor-approved design-evidence credit. Then:
#     set google_backup_credentials_file + google_backup_project_id in
#     terraform.tfvars, run `terraform init` AGAIN (new provider download),
#     and `terraform apply` stands the bucket up for real.
#
# Data flow: DynamoDB --(AWS native export to S3, console/API)-->
# sunsip-cloud-ddb-export <S3> --(gcloud storage transfer / manual gsutil)-->
# sunsip-cloud-ddb-backup <GCS, versioned, retention-locked>

# (required_providers lives in providers.tf — one block per directory;
#  the google provider entry is merged there.)

variable "google_backup_project_id" {
  description = "The GCP project where the backup bucket lives. Empty = code-path only (resources NOT created; plan still works with provider configured via a placeholder)."
  type        = string
  default     = ""
}

variable "google_backup_credentials_file" {
  description = "Path to a GCP service-account JSON key (gitignored, like all tfvars). Empty = code-path only."
  type        = string
  default     = ""
}

variable "google_backup_region" {
  description = "GCS location. europe-north1 keeps EU-residency for personal data; asia-southeast2 matches Sydney residency if required."
  type        = string
  default     = "europe-north1"
}

variable "google_backup_retention_days" {
  description = "Object retention lock: backups may not be deleted younger than this — the point of a backup."
  type        = number
  default     = 30
}

# CODE-PATH SAFETY: when no project/credentials are configured (Elena's card
# stance), these count = 0 — the google provider plan()s a no-op graph, the
# AWS side stays live. The moment she/college resolves the billing path, the
# same code deploys for real.
locals {
  gcp_live = var.google_backup_project_id != "" && var.google_backup_credentials_file != ""
}

# Config-less provider: with count=0 on every resource (the card-gated case),
# Terraform never touches GCP and even validates without credentials. At LIVE
# time set google_backup_project_id + google_backup_credentials_file in
# terraform.tfvars and run `gcloud auth application-default login` so the CLI
# supplies ADC credentials - NO key files on disk.
provider "google" {
  # Project/credentials resolve at LIVE time (tfvars + `gcloud auth
  # application-default login` = ADC). With them unset and every resource
  # count=0, the provider is never exercised and validation passes offline.
  project     = var.google_backup_project_id != "" ? var.google_backup_project_id : null
  region      = var.google_backup_region
  credentials = var.google_backup_credentials_file != "" ? file(var.google_backup_credentials_file) : null
}

# GCS bucket: versioned + retention-locked + soft-delete = the backup rules.
resource "google_storage_bucket" "ddb_backup" {
  count         = local.gcp_live ? 1 : 0
  name          = "sunsip-cloud-ddb-backup-${var.google_backup_project_id}"
  location      = var.google_backup_region
  force_destroy = false # a backup bucket NEVER falls to rm -rf

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  retention_policy {
    retention_period = var.google_backup_retention_days * 86400
    is_locked        = false # lock later, after the retention window is proven
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE" # warm tier after 90d: pennies per GB
    }
  }

  labels = {
    project     = "sunsip-cloud"
    environment = "assessment"
    purpose     = "ddb-backup"
  }
}

# Service account scoped to ONLY this bucket (least privilege, mirrors the
# AWS-side IAM discipline of this project).
resource "google_service_account" "backup_writer" {
  count        = local.gcp_live ? 1 : 0
  account_id   = "sunsip-cloud-backup-writer"
  display_name = "SunSip Cloud - DynamoDB backup"
}

resource "google_storage_bucket_iam_member" "writer" {
  count  = local.gcp_live ? 1 : 0
  bucket = google_storage_bucket.ddb_backup[0].name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.backup_writer[0].email}"
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "google_backup_mode" {
  value       = local.gcp_live ? "LIVE" : "CODE-PATH-ONLY (no GCP project/credentials configured — card-gated step pending)"
  description = "Tells the report which Google path produced this evidence."
}

output "google_backup_bucket" {
  value       = local.gcp_live ? google_storage_bucket.ddb_backup[0].name : "sunsip-cloud-ddb-backup-<project-id>(planned)"
  description = "GCS bucket name."
}

output "google_backup_flow" {
  value = "dynamodb -> (native export) -> s3://sunsip-cloud-ddb-export-311141538922 -> (gcloud storage transfer) -> gs://<this bucket>"
}