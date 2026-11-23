# Phase 2 Step 5c-1 — Task-side IAM (brief section C: least-privilege roles).
#
# TWO roles per Fargate task, each with one job:
#   execution role — what the ECS DAEMON does to START the task:
#     pull images from ECR, fetch secrets, write container logs.
#   task role      — what the RUNNING APP does: user-collection reads/writes
#     the sunsip-data table; both write their own CloudWatch log streams.
#
# Least privilege as scored: the task roles name the ONE table ARN (not
# "*"), and log permissions name the service log groups (not all logs).
# The execution role reuses AWS's managed policy — it can only pull images
# and write logs, nothing else.

# ------------------------------------------------------- execution role
# Shared by both services (identical needs: ECR pull + awslogs driver).

resource "aws_iam_role" "ecs_execution" {
  name = "${var.project_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-ecs-execution-role" })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ------------------------------------------------------------ task roles

resource "aws_iam_role" "task_city" {
  name = "${var.project_name}-task-city-role"

  # Same trust policy shape as the execution role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-task-city-role" })
}

# city-experience touches NO database — its role only writes logs.
resource "aws_iam_role_policy" "task_city_logs" {
  name = "city-logs"
  role = aws_iam_role.task_city.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.city.arn}:*"
    }]
  })
}

resource "aws_iam_role" "task_user" {
  name = "${var.project_name}-task-user-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-task-user-role" })
}

# user-collection: exactly the DynamoDB statements the service uses,
# scoped to the one table this project owns.
resource "aws_iam_role_policy" "task_user_dynamodb" {
  name = "user-dynamodb-plain"
  role = aws_iam_role.task_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
        "dynamodb:DescribeTable",
      ]
      Resource = [
        aws_dynamodb_table.sunsip_data.arn,
        "${aws_dynamodb_table.sunsip_data.arn}/index/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "task_user_logs" {
  name = "user-logs"
  role = aws_iam_role.task_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.user.arn}:*"
    }]
  })
}

# ------------------------------------------------------------------ outputs

output "task_role_arns" {
  value = {
    city = aws_iam_role.task_city.arn
    user = aws_iam_role.task_user.arn
  }
}