# Phase 4 / Step 8-1 — Storage & alerts (brief section D):
#   1. artifacts bucket — PRIVATE + versioned; CodePipeline zips land here
#      (Phase 5). No public access ever.
#   2. static site bucket — holds the built React FE. Public access is
#      BLOCKED at the bucket; the CloudFront distribution (cdn.tf) is the
#      ONLY reader via Origin Access Control (signed SigV4 requests).
#      Delivery goes through the CDN's HTTPS, never an open bucket —
#      that's the security story for the report.
#   3. SNS topic — ONE alert fan-out point: failed deploys (wired in
#      Phase 5) + scaling alarms (the four Phase 3 alarms gain this ARN
#      in alerts.tf). Email subscription below — Elena CONFIRMS it once
#      from the AWS-issued email (aws marks it PendingConfirmation
#      until she clicks).
#
# Bucket names are GLOBAL across all AWS accounts — project + account id
# keeps them unique (same pattern as the state bucket).
# force_destroy = true: this account is torn down after every working
# session; a "bucket not empty" error at destroy time is a wasted evening.

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project_name}-artifacts-311141538922"
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-artifacts" })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "site" {
  bucket        = "${var.project_name}-site-311141538922"
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-static-site" })
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket's own policy: allow ONLY the CloudFront distribution to read.
# The Condition pins it to THIS distribution's ARN — even another
# distribution in the account could not read the site.

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontReadOnlyGet"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.site.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.main.arn
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic" "alerts" {
  name         = "${var.project_name}-alerts"
  display_name = "SunSip Cloud Alerts"

  tags = merge(local.common_tags, { Name = "${var.project_name}-alerts" })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ------------------------------------------------------------------ outputs

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "site_bucket" {
  value = aws_s3_bucket.site.bucket
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "alerts_email_pending" {
  description = "Check the inbox for the AWS confirmation email and click Confirm subscription."
  value       = var.alert_email
}