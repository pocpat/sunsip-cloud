# ─── Phase 7: Azure Entra ID SAML federation (assessment brief G) ─────────────
# The Entra side (enterprise app AWS-SunSip, SAML, entity id, reply URL, the
# group + the Role claim) is portal-owned — Microsoft Graph apps are outside
# Terraform's AWS provider. This file is the AWS half, built for least
# privilege and documented in the report:
#   1. aws_iam_saml_provider consumes the app's Federation Metadata XML
#      (entra-metadata.xml — public certs + endpoints, no secrets, committed).
#   2. Two roles TRUST that provider via sts:AssumeRoleWithSAML, audience-
#      restricted to the AWS console's SAML endpoint:
#        DevOpsEngineer  — least-privilege operational access
#        ReadOnlyAuditor — read-only, explicitly denies PassRole/permissions
#   3. Outputs emit the exact claim values the Entra portal needs
#      ("role-arn,idp-arn" CSVs) — the portal step after `apply` just pastes them.

# The IdP — metadata file downloaded from the Entra app's SSO page.
resource "aws_iam_saml_provider" "entra" {
  name                   = "entra-id"
  saml_metadata_document = file("${path.module}/entra-metadata.xml")
}

# ── DevOpsEngineer: scoped operational policy (not admin) ────────────────────
data "aws_iam_policy_document" "devops_engineer" {
  statement {
    sid    = "ReadContainersAndNetwork"
    effect = "Allow"
    actions = [
      "ecs:Describe*", "ecr:Describe*", "ecr:GetDownloadUrlForLayer",
      "ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability",
      "ec2:Describe*", "elasticloadbalancing:Describe*", "cloudfront:Get*", "cloudfront:List*",
      "s3:Get*", "s3:List*", "cloudwatch:Get*", "cloudwatch:List*",
      "logs:Get*", "logs:Describe*", "logs:FilterLogEvents", "logs:Tail",
      "deploy:Get*", "deploy:List*", "codedeploy:Get*", "codedeploy:List*",
      "codepipeline:Get*", "codepipeline:List*", "iam:Get*", "iam:List*",
      "dynamodb:Query", "dynamodb:Scan", "dynamodb:DescribeTable",
      "sns:Subscribe", "sns:Unsubscribe", "sns:List*",
    ]
    resources = ["*"]
  }
}

# ── ReadOnlyAuditor: read-only, with explicit denies a pure read policy can't ─
data "aws_iam_policy_document" "read_only_auditor" {
  statement {
    sid    = "ReadEverythingForAudits"
    effect = "Allow"
    actions = [
      "ecs:Describe*", "ecr:Describe*", "ec2:Describe*",
      "elasticloadbalancing:Describe*", "cloudfront:List*",
      "s3:Get*", "s3:List*", "cloudwatch:Get*", "cloudwatch:Describe*",
      "logs:Get*", "logs:Describe*", "logs:FilterLogEvents",
      "deploy:Get*", "deploy:List*", "codepipeline:Get*", "codepipeline:List*",
      "iam:Get*", "iam:List*", "dynamodb:Get*", "dynamodb:Query", "dynamodb:Scan",
      "sns:Get*", "sns:List*", "identitystore:Describe*",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "NoMutationsBeyondReads"
    effect    = "Deny"
    actions   = ["iam:PassRole", "iam:CreateRole", "iam:AttachRolePolicy", "s3:PutObject", "s3:DeleteObject"]
    resources = ["*"]
  }
}

# ── The two SAML-federated roles ──────────────────────────────────────────────
resource "aws_iam_role" "saml" {
  for_each              = { DevOpsEngineer = data.aws_iam_policy_document.devops_engineer, ReadOnlyAuditor = data.aws_iam_policy_document.read_only_auditor }
  name                  = "${var.project_name}-${each.key}"
  description           = "SAML-federated via Azure Entra ID (assessment brief G); assigned through Entra groups."
  max_session_duration  = 3600
  force_detach_policies = true

  # Trust = the Entra SAML provider; audience = the console's SAML endpoint.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_saml_provider.entra.arn }
        Action    = "sts:AssumeRoleWithSAML"
        Condition = {
          StringEquals = { "SAML:aud" = "https://signin.aws.amazon.com/saml" }
        }
      }
    ]
  })

  inline_policy {
    name   = "${var.project_name}-${each.key}-policy"
    policy = each.value.json
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-${each.key}" })
}

# ── Outputs = the exact strings the Entra portal claim needs ─────────────────
# The Entra "Role" attribute takes one value per role: "role-arn,idp-arn".
output "entra_saml_provider_arn" {
  value       = aws_iam_saml_provider.entra.arn
  description = "IAM SAML provider ARN (paste with each role ARN into the Entra Role claim)."
}

output "saml_role_claims" {
  value = [
    for name, role in aws_iam_role.saml : "${role.arn},${aws_iam_saml_provider.entra.arn}"
  ]
  description = "One CSV per role - paste each as a separate AttributeValue in the Entra https://aws.amazon.com/SAML/Attributes/Role claim."
}