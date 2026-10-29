# Targeted apply - Phase 2 first-build order: the 2 ECR repos + the ECS cluster.
# Usage (from this infra\main folder):  .\apply-targeted.ps1   then answer 'yes'
#
# Why this file exists: PowerShell splits any argument that starts with a dash
# and contains a dot ("-target=a.b" → "-target=a" + ".b") — a parser quirk,
# present in script files TOO, not just console paste. Verified 20 Oct: the
# SAME flags quoted arrive intact, so the targets below carry double quotes.
terraform apply -target="aws_ecr_repository.city_experience" -target="aws_ecr_repository.user_collection" -target="aws_ecs_cluster.main"