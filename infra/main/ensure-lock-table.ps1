# Recreates the Terraform state-lock table (sunsip-cloud-tf-locks) if missing.
# Why: Terraform 1.15.x no longer auto-creates it during `terraform init` -
# without it, apply fails with 'Error acquiring the state lock'.
# Usage (from infra\main):  .\ensure-lock-table.ps1   - wait ~5-10 s for ACTIVE.
# Idempotent: exits cleanly if the table already exists.
$table = 'sunsip-cloud-tf-locks'
$null = aws dynamodb describe-table --table-name $table --profile terraform-sunsip --region ap-southeast-2 2>$null
if ($LASTEXITCODE -eq 0) {
  Write-Host "Lock table '$table' already exists - nothing to do."
  exit 0
}
aws dynamodb create-table --table-name $table --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST --profile terraform-sunsip --region ap-southeast-2
if ($LASTEXITCODE -eq 0) {
  Write-Host "Creating lock table - waiting for it to become ACTIVE..."
  aws dynamodb wait table-exists --table-name $table --profile terraform-sunsip --region ap-southeast-2
  Write-Host "Lock table '$table' is ACTIVE. Continue with row 7 (.\apply-targeted.ps1)."
}