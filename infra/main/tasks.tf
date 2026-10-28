# Phase 2 Step 5c-2 + data layer — TWO log groups, the ONE DynamoDB table
# (brief: "ONE DynamoDB table, app transaction data"), and TWO task
# definitions (brief section B item 3: Fargate, CPU/memory + ECR images).
#
# The real sunsip-data table is Terraform-owned; the local create-table.js
# script exists only for DynamoDB-local dev. Same PK/SK/GSI schema as the
# script so the service code runs unmodified against both.
#
# healthz note: user-collection's /healthz does a REAL GetItem round-trip,
# which is why the table + task-user-role land in the SAME file set as the
# services — by the time ECS reports a task running, health checks pass.

# ------------------------------------------------------------ cloudwatch logs

resource "aws_cloudwatch_log_group" "city" {
  name              = "/ecs/${var.project_name}/city-experience"
  retention_in_days = 7 # keep costs at zero for short sessions

  tags = merge(local.common_tags, { Name = "${var.project_name}-logs-city" })
}

resource "aws_cloudwatch_log_group" "user" {
  name              = "/ecs/${var.project_name}/user-collection"
  retention_in_days = 7

  tags = merge(local.common_tags, { Name = "${var.project_name}-logs-user" })
}

# ------------------------------------------------------------ dynamodb table

resource "aws_dynamodb_table" "sunsip_data" {
  name         = "sunsip-data"
  billing_mode = "PAY_PER_REQUEST" # matches local design; ~free at assessment traffic
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "GSI1PK"
    type = "S"
  }
  attribute {
    name = "GSI2PK"
    type = "S"
  }
  attribute {
    name = "GSI2SK"
    type = "S"
  }

  # Time-ordered access (newest-first favourites per user)
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "SK"
    projection_type = "ALL"
  }

  # Email lookup (sign-in, forgot-password, duplicate-signup check)
  global_secondary_index {
    name            = "GSI2"
    hash_key        = "GSI2PK"
    range_key       = "GSI2SK"
    projection_type = "ALL"
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-dynamodb" })
}

# ---------------------------------------------------------- task definitions

resource "aws_ecs_task_definition" "city_experience" {
  family                   = "${var.project_name}-city-experience"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # Fargate: every task gets its own ENI
  cpu                      = 256      # 0.25 vCPU
  memory                   = 512      # 0.5 GB — cheapest Fargate size
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.task_city.arn

  container_definitions = jsonencode([
    {
      name      = "city-experience"
      image     = "${aws_ecr_repository.city_experience.repository_url}:latest"
      essential = true

      portMappings = [{
        containerPort = 4001 # the service's real listen port
        protocol      = "tcp"
      }]

      environment = [
        { name = "PORT", value = "4001" },
        { name = "NODE_ENV", value = "production" },
        # Server-side key: real OpenWeather when set, the designed mock when empty.
        { name = "OPENWEATHER_API_KEY", value = var.openweather_api_key },
        # Real IMAGE + LANDMARK chain (27 Oct fix): keys empty = designed mock
        # fallbacks keep serving; values live in terraform.tfvars (gitignored).
        { name = "IMAGEROUTER_API_KEY", value = var.imagerouter_api_key },
        { name = "CLOUDFLARE_API_KEY", value = var.cloudflare_api_key },
        { name = "CLOUDFLARE_ACCOUNT_ID", value = var.cloudflare_account_id },
        { name = "OPENROUTER_API_KEY", value = var.openrouter_api_key },
        { name = "VITE_OPENROUTER_TEXT_MODEL", value = var.openrouter_text_model },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.city.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "city"
        }
      }
    }
  ])

  tags = merge(local.common_tags, { Name = "${var.project_name}-city-taskdef" })
}

resource "aws_ecs_task_definition" "user_collection" {
  family                   = "${var.project_name}-user-collection"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.task_user.arn

  container_definitions = jsonencode([
    {
      name      = "user-collection"
      image     = "${aws_ecr_repository.user_collection.repository_url}:latest"
      essential = true

      portMappings = [{
        containerPort = 4002
        protocol      = "tcp"
      }]

      environment = [
        { name = "PORT", value = "4002" },
        { name = "NODE_ENV", value = "production" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "DDB_TABLE", value = "sunsip-data" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.user.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "user"
        }
      }
    }
  ])

  tags = merge(local.common_tags, { Name = "${var.project_name}-user-taskdef" })
}

# ------------------------------------------------------------------ outputs

output "task_def_arns" {
  value = {
    city = aws_ecs_task_definition.city_experience.arn
    user = aws_ecs_task_definition.user_collection.arn
  }
}