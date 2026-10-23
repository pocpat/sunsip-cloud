# Phase 5 / Step 9 — CI/CD (brief section E): least-privilege IAM, TWO CodeBuild
# projects (build Docker image + push ECR), TWO CodeDeploy apps (ECS blue/green,
# zero-downtime), ONE CodePipeline Source -> parallel Builds -> parallel Deploys.
#
# How the machine moves (the report story):
#   git push (branch phase1-microservices, CodeStar connection auto-triggers)
#     -> CodePipeline "Source"      zips the repo                    (SourceArtifact)
#     -> "Build"   TWO CodeBuild projects IN PARALLEL (RunOrder equal)
#          docker build -> push :latest + :<commit-sha> to each ECR repo
#          describe-task-definition -> rendered taskdef.json (image = <IMAGE1_NAME>)
#          imageDetail.json = {"ImageURI": "<repo>:<sha>"}   (deploy input)
#     -> "Deploy"  TWO CodeDeployToECS actions IN PARALLEL
#          appspec.yaml from the SOURCE artifact (deploy/<service>/)
#          taskdef.json + imageDetail.json from the BUILD artifact
#          placeholders <TASK_DEFINITION> and <IMAGE1_NAME> resolved by the action
#          -> CodeDeploy BLUE/GREEN: new green task set on the GREEN target group,
#             production listener re-pointed blue->green, old blue terminated
#             (wait 10 min), rollback on DEPLOYMENT_FAILURE.
#
# Blue/green wiring notes (per AWS docs "CodeDeploy blue/green for ECS"):
#   - the ECS service KEEPS its load_balancer block (the BLUE target group) and
#     changes to deployment_controller CODE_DEPLOY (services.tf, forces replace)
#   - the deployment group defines the TARGET GROUP PAIR (blue + green) and the
#     production listener the traffic route re-points
#   - the green target group is never attached in Terraform: CodeDeploy attaches
#     it by re-pointing the listener only for the duration of a deployment
#   - taskdef.json is GENERATED at build time from the live task definition, so
#     env vars injected via terraform.tfvars (OPENWEATHER_API_KEY) ride along —
#     no secret is committed to the repo (that artifact zip lives in the private
#     artifacts bucket)
#   - failed pipeline -> SNS alert (section D ties the existing topic in)
#
# Cost guard: CodeBuild free tier = 100 build minutes/month (general1.small);
# CodeDeploy + CodePipeline are free. A session's few builds stay inside it.

variable "pipeline_branch" {
  description = "Git branch the pipeline watches. Services code + Dockerfiles live only on the Terraform work branch, not main."
  type        = string
  default     = "phase1-microservices"
}

# ── GitHub connection — CONSOLE-OWNED (see P5.1 notes) ────────────────────────
# Elena created + authorized a GitHub connection BY HAND in the console
# (connections named "pocpat"), which is BETTER than the Terraform-managed
# form: a connection created by hand is NOT in Terraform state, therefore it
# SURVIVES teardown + every rebuild — no per-session re-auth click. The ARN is
# a plain identifier (not a credential), so it can live in code. If the manual
# app scope ever misses the sunsip-cloud repo, re-run the connection's
# "Update pending connection" flow in the console and paste the new ARN here.
variable "github_connection_arn" {
  description = "Console-created CodeStar connection (GitHub), authorized manually once; survives teardowns."
  type        = string
  default     = "arn:aws:codeconnections:ap-southeast-2:311141538922:connection/7e6b6ce6-ec47-4020-a20f-066947db0434"
}

# ── Green (replacement) target groups — same LB, same protocol/health as blue ─
resource "aws_lb_target_group" "city_experience_green" {
  name        = "${var.project_name}-tg-city-green"
  port        = 4001
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-tg-city-green" })
}

resource "aws_lb_target_group" "user_collection_green" {
  name        = "${var.project_name}-tg-user-green"
  port        = 4002
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-tg-user-green" })
}

# ── CodeDeploy service role (blue/green controller on our behalf) ─────────────
# Least-privilege note: the AWS-managed AWSCodeDeployRoleForECS is the scoped,
# supported policy for ECS blue/green (ECS APIs + ELB listener re-point +
# CloudWatch alarms + SNS); a hand-rolled copy drifts and is the classic
# blue/green failure mode. The attachment is deliberately explicit in plan output.
resource "aws_iam_role" "codedeploy_service" {
  name = "${var.project_name}-codedeploy-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.common_tags, { Name = "${var.project_name}-codedeploy-role" })
}

resource "aws_iam_role_policy_attachment" "codedeploy_service_managed" {
  role       = aws_iam_role.codedeploy_service.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# ── CodeDeploy app + deployment group, one pair per service ───────────────────
resource "aws_codedeploy_app" "city" {
  name             = "${var.project_name}-cd-city"
  compute_platform = "ECS"
  tags             = merge(local.common_tags, { Name = "${var.project_name}-cd-city" })
}

resource "aws_codedeploy_app" "user" {
  name             = "${var.project_name}-cd-user"
  compute_platform = "ECS"
  tags             = merge(local.common_tags, { Name = "${var.project_name}-cd-user" })
}

resource "aws_codedeploy_deployment_group" "city" {
  app_name               = aws_codedeploy_app.city.name
  deployment_group_name  = "${var.project_name}-dg-city"
  service_role_arn       = aws_iam_role.codedeploy_service.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  # ECS blue/green REQUIRES the style to be BLUE_GREEN + WITH_TRAFFIC_CONTROL —
  # the API rejects anything else (InvalidDeploymentStyleException, seen live
  # 23 Oct). WITH_TRAFFIC_CONTROL = the listener re-point (the production
  # listener gets updated by CodeDeploy during the cutover).
  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.city_experience.name
  }

  # the BLUE/GREEN target-group pair + the production listener CodeDeploy re-points
  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.city_experience_http.arn]
      }
      target_group { name = aws_lb_target_group.city_experience.name }
      target_group { name = aws_lb_target_group.city_experience_green.name }
    }
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT" # zero-touch cutover; no manual gate to babysit
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 10 # 10 min on the old task set for a quick manual undo
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"] # NOT ALARMS: the CPU alarms are normal scaling life
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-dg-city" })
}

resource "aws_codedeploy_deployment_group" "user" {
  app_name               = aws_codedeploy_app.user.name
  deployment_group_name  = "${var.project_name}-dg-user"
  service_role_arn       = aws_iam_role.codedeploy_service.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  # Same required style as the city group (see its comment).
  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.user_collection.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.user_collection_http.arn]
      }
      target_group { name = aws_lb_target_group.user_collection.name }
      target_group { name = aws_lb_target_group.user_collection_green.name }
    }
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 10
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-dg-user" })
}

# ── CodeBuild role + project, one per microservice (least privilege) ──────────
# Each project: only its OWN ECR repo + the shared artifacts bucket + its own
# log group + the describe-task-definition read its buildspec needs.
resource "aws_iam_role" "codebuild" {
  for_each = { city = "city-experience", user = "user-collection" }
  name     = "${var.project_name}-codebuild-${each.key}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.common_tags, { Name = "${var.project_name}-codebuild-${each.key}-role" })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  for_each = { city = "city-experience", user = "user-collection" }
  role     = aws_iam_role.codebuild[each.key].id
  # city uses the city ECR repo; user the user one (sunsip-cloud-<svc> -> var form)
  name = "${var.project_name}-codebuild-${each.key}-least-priv"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "ECR"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken", # registry-level operation, cannot be repo-scoped
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRRepo"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = each.key == "city" ? aws_ecr_repository.city_experience.arn : aws_ecr_repository.user_collection.arn
      },
      {
        Sid    = "S3Artifacts"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:log-group:/aws/codebuild/*"
      },
      ], each.key == "city" ? [
      {
        Sid      = "DescribeCityTaskDef"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition"]
        Resource = "arn:aws:ecs:*:*:task-definition/${var.project_name}-city-experience*"
      }
      ] : [
      {
        Sid      = "DescribeUserTaskDef"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition"]
        Resource = "arn:aws:ecs:*:*:task-definition/${var.project_name}-user-collection*"
      }
    ])
  })
}

# The buildspec is inline (yamlencode) so the whole CI/CD design lives in one
# .tf file — no drift between a committed buildspec.yml and Terraform.
# post_build renders taskdef.json from the LIVE task definition (whitelist of
# register-task-definition input keys only; describe output carries report-only
# fields that register rejects) with the image swapped for the <IMAGE1_NAME>
# placeholder the CodeDeployToECS action fills from imageDetail.json.
locals {
  codebuild_specs = {
    city = yamlencode({
      version = "0.2"
      phases = {
        pre_build = {
          commands = [
            "aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin ${aws_ecr_repository.city_experience.repository_url}",
            "REPO_URI=${aws_ecr_repository.city_experience.repository_url}",
          ]
        }
        build = {
          commands = [
            "docker build -t \"$REPO_URI:latest\" -t \"$REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION\" services/city-experience",
          ]
        }
        post_build = {
          commands = [
            "docker push $REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION",
            "docker push $REPO_URI:latest",
            "printf '{\"ImageURI\":\"%s\"}' \"$REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION\" > imageDetail.json",
            "aws ecs describe-task-definition --task-definition ${var.project_name}-city-experience --query 'taskDefinition' --output json > full.json",
            "python3 -c \"import json;d=json.load(open('full.json'));keep=('family','networkMode','containerDefinitions','requiresCompatibilities','cpu','memory','executionRoleArn','taskRoleArn','volumes','placementConstraints','runtimePlatform');out={k:d[k] for k in keep if k in d};out['containerDefinitions'][0]['image']='<IMAGE1_NAME>';json.dump(out,open('taskdef.json','w'))\"",
          ]
        }
      }
      artifacts = {
        files = ["taskdef.json", "imageDetail.json"]
      }
    })
    user = yamlencode({
      version = "0.2"
      phases = {
        pre_build = {
          commands = [
            "aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin ${aws_ecr_repository.user_collection.repository_url}",
            "REPO_URI=${aws_ecr_repository.user_collection.repository_url}",
          ]
        }
        build = {
          commands = [
            "docker build -t \"$REPO_URI:latest\" -t \"$REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION\" services/user-collection",
          ]
        }
        post_build = {
          commands = [
            "docker push $REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION",
            "docker push $REPO_URI:latest",
            "printf '{\"ImageURI\":\"%s\"}' \"$REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION\" > imageDetail.json",
            "aws ecs describe-task-definition --task-definition ${var.project_name}-user-collection --query 'taskDefinition' --output json > full.json",
            "python3 -c \"import json;d=json.load(open('full.json'));keep=('family','networkMode','containerDefinitions','requiresCompatibilities','cpu','memory','executionRoleArn','taskRoleArn','volumes','placementConstraints','runtimePlatform');out={k:d[k] for k in keep if k in d};out['containerDefinitions'][0]['image']='<IMAGE1_NAME>';json.dump(out,open('taskdef.json','w'))\"",
          ]
        }
      }
      artifacts = {
        files = ["taskdef.json", "imageDetail.json"]
      }
    })
  }
}

# Linux container with Docker available; privileged_mode is REQUIRED for
# docker-in-docker builds (default false -> build dies at the docker command).
resource "aws_codebuild_project" "build" {
  for_each      = { city = "city-experience", user = "user-collection" }
  name          = "${var.project_name}-build-${each.key}"
  service_role  = aws_iam_role.codebuild[each.key].arn
  build_timeout = "10"

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL" # free-tier 100 min/month friendly
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # docker-in-docker — REQUIRED for docker build/push
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = local.codebuild_specs[each.key]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-build-${each.key}" })
}

# ── CodePipeline role (least privilege over all the steps it performs) ────────
resource "aws_iam_role" "pipeline" {
  name = "${var.project_name}-pipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codepipeline.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
      # The EventBridge-based auto-trigger of the GitHub connection source action
      # is started by CodePipeline itself; the SNS-failure rule is covered in the
      # topic policy below, so no events.amazonaws.com entry is needed here.
    ]
  })
  tags = merge(local.common_tags, { Name = "${var.project_name}-pipeline-role" })
}

resource "aws_iam_role_policy" "pipeline_policy" {
  name = "${var.project_name}-pipeline-least-priv"
  role = aws_iam_role.pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Artifacts"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },
      {
        Sid      = "CodeBuild"
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:StopBuild", "codebuild:BatchGetBuilds"]
        Resource = [aws_codebuild_project.build["city"].arn, aws_codebuild_project.build["user"].arn]
      },
      {
        Sid    = "CodeDeploy"
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          "codedeploy:ListDeploymentConfigs",
          "codedeploy:RegisterApplicationRevision",
          "codedeploy:StopDeployment",
        ]
        Resource = "*"
      },
      {
        Sid    = "SourceConnection"
        Effect = "Allow"
        Action = [
          "codestar-connections:UseConnection",
          "codeconnections:UseConnection", # renamed API surface, same object
        ]
        Resource = "*"
      },
      {
        Sid      = "TaskDefRevision"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
        Resource = "arn:aws:ecs:*:*:task-definition/${var.project_name}-*"
      },
      {
        Sid      = "PassTaskRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [aws_iam_role.task_city.arn, aws_iam_role.task_user.arn, aws_iam_role.ecs_execution.arn]
      },
    ]
  })
}

# ── THE pipeline: Source -> parallel Builds -> parallel Deploys ───────────────
# ONE pipeline (brief E-4); the two Build actions share RunOrder = parallel, and
# so do the two Deploy actions. The Source action output (SourceArtifact) feeds
# both builds; each build produces its own taskdef+image artifact pair.
resource "aws_codepipeline" "main" {
  name          = "${var.project_name}-pipeline"
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V1"

  tags = merge(local.common_tags, { Name = "${var.project_name}-pipeline" })

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name      = "GitHub-source"
      category  = "Source"
      owner     = "AWS"
      provider  = "CodeStarSourceConnection"
      version   = "1"
      run_order = 1

      output_artifacts = ["SourceArtifact"]

      configuration = {
        ConnectionArn    = var.github_connection_arn
        FullRepositoryId = "pocpat/sunsip-cloud"
        BranchName       = var.pipeline_branch
      }
    }
  }

  stage {
    name = "Build"

    action {
      name      = "Build-city-experience"
      category  = "Build"
      owner     = "AWS"
      provider  = "CodeBuild"
      version   = "1"
      run_order = 1 # same RunOrder as its sibling = they run IN PARALLEL

      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["CityBuild"]
      configuration = {
        ProjectName = aws_codebuild_project.build["city"].name
      }
    }

    action {
      name      = "Build-user-collection"
      category  = "Build"
      owner     = "AWS"
      provider  = "CodeBuild"
      version   = "1"
      run_order = 1

      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["UserBuild"]
      configuration = {
        ProjectName = aws_codebuild_project.build["user"].name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name      = "Deploy-city-experience"
      category  = "Deploy"
      owner     = "AWS"
      provider  = "CodeDeployToECS"
      version   = "1"
      run_order = 1

      input_artifacts = ["SourceArtifact", "CityBuild"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.city.name
        DeploymentGroupName            = aws_codedeploy_deployment_group.city.deployment_group_name
        AppSpecTemplateArtifact        = "SourceArtifact"
        AppSpecTemplatePath            = "deploy/city-experience/appspec.yaml"
        TaskDefinitionTemplateArtifact = "CityBuild"
        TaskDefinitionTemplatePath     = "taskdef.json"
        Image1ArtifactName             = "CityBuild"
        Image1ContainerName            = "IMAGE1_NAME" # the placeholder NAME; taskdef.json carries <IMAGE1_NAME>
      }
    }

    action {
      name      = "Deploy-user-collection"
      category  = "Deploy"
      owner     = "AWS"
      provider  = "CodeDeployToECS"
      version   = "1"
      run_order = 1

      input_artifacts = ["SourceArtifact", "UserBuild"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.user.name
        DeploymentGroupName            = aws_codedeploy_deployment_group.user.deployment_group_name
        AppSpecTemplateArtifact        = "SourceArtifact"
        AppSpecTemplatePath            = "deploy/user-collection/appspec.yaml"
        TaskDefinitionTemplateArtifact = "UserBuild"
        TaskDefinitionTemplatePath     = "taskdef.json"
        Image1ArtifactName             = "UserBuild"
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }
}

# ── Failed deployment -> SNS alert (brief section D) ──────────────────────────
resource "aws_cloudwatch_event_rule" "pipeline_failed" {
  name = "${var.project_name}-pipeline-failed"
  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      state = ["FAILED"]
    }
  })
  tags = merge(local.common_tags, { Name = "${var.project_name}-pipeline-failed" })
}

resource "aws_cloudwatch_event_target" "pipeline_failed_sns" {
  rule      = aws_cloudwatch_event_rule.pipeline_failed.name
  target_id = "${var.project_name}-alert-topic"
  arn       = aws_sns_topic.alerts.arn
}

# EventBridge needs the topic to accept its publish; SourceArn condition is the
# least-privilege pin on exactly this rule.
resource "aws_sns_topic_policy" "alerts_event_publish" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeFailedDeploys"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
      Condition = { ArnEquals = { "AWS:SourceArn" = aws_cloudwatch_event_rule.pipeline_failed.arn } }
    }]
  })
}

# ── Outputs for console-free verification + the runbook ───────────────────────
output "codebuild_project_names" {
  value = [aws_codebuild_project.build["city"].name, aws_codebuild_project.build["user"].name]
}

output "codedeploy_app_names" {
  value = [aws_codedeploy_app.city.name, aws_codedeploy_app.user.name]
}

output "pipeline_name" {
  value = aws_codepipeline.main.name
}

output "green_target_group_arns" {
  value = {
    city = aws_lb_target_group.city_experience_green.arn
    user = aws_lb_target_group.user_collection_green.arn
  }
}