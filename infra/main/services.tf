# Phase 2 Step 5c-3 — TWO ECS services (brief section B item 4): each runs
# one Fargate task, registers into its OWN existing ALB target group
# (Step 4), and spreads across the service's two-AZ public subnets (HA).
#
# Networking shape: Fargate tasks get their own ENI (network_mode awsvpc).
# Tasks live in the PUBLIC subnets WITH assign_public_ip = true — this is
# the documented no-NAT-gateway pattern: the task's public IP reaches ECR
# and the internet through the IGW, while the nested SGs still allow
# inbound ONLY from the ALB SGs (Step 3). A NAT gateway would add ~$33/mo;
# skipped deliberately for cost, documented in the report.
#
# health_check_grace_period_seconds = 60: node needs ~15-20s to boot before
# /healthz passes; without the grace period the first checks can mark a
# healthy-but-slow task unhealthy and cause a restart loop.

resource "aws_ecs_service" "city_experience" {
  name            = "${var.project_name}-city-experience"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.city_experience.arn
  desired_count   = 1 # min Fargate footprint; autoscaling raises it in Step 7
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.city_experience[*].id # city tier, AZ-a + AZ-b
    security_groups  = [aws_security_group.tasks_city_experience.id]
    assign_public_ip = true # no NAT gateway — see header comment
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.city_experience.arn
    container_name   = "city-experience"
    container_port   = 4001
  }

  health_check_grace_period_seconds = 60

  # The task definition ownership note: see the user service below — Terraform
  # registers the bootstrap def; the pipeline (CodeDeploy) rolls later revisions;
  # this pointer is ignored to avoid drift-fighting.
  # load_balancers added (29 Oct): ECS forbids updating load balancers on
  # CODE_DEPLOY services (only CodeDeploy may); blue/green wiring is
  # CodeDeploy-owned, so Terraform must ignore it or UpdateService fails.
  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

  # Race fix (29 Oct): this CODE_DEPLOY service validates that its target
  # group is already attached to a listener at CreateService time — both
  # resources depend on the same TG, so creation order is a race. Anchor the
  # service to the LISTENER so the attachment always exists first (live
  # InvalidParameterException "does not have an associated load balancer").
  depends_on = [aws_lb_listener.city_experience_http]

  # Phase 5: CodeDeploy blue/green — the controller change FORCES a service
  # replacement (ECS cannot switch a running service's controller). The service
  # KEEPS its load_balancer block (the blue target group); the green target
  # group + listener re-point live in the CodeDeploy deployment group (cicd.tf).
  deployment_controller {
    type = "CODE_DEPLOY"
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-city-service" })
}

resource "aws_ecs_service" "user_collection" {
  name            = "${var.project_name}-user-collection"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.user_collection.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.user_collection[*].id # user tier, AZ-a + AZ-b
    security_groups  = [aws_security_group.tasks_user_collection.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.user_collection.arn
    container_name   = "user-collection"
    container_port   = 4002
  }

  health_check_grace_period_seconds = 60

  # Same listener-attachment race fix as the city service.
  depends_on = [aws_lb_listener.user_collection_http]

  # The task definition now has TWO owners by design: Terraform registers the
  # BOOTSTRAP revision (image = :latest, env incl. the tfvars keys); the PIPELINE
  # (CodeDeploy blue/green) rolls every later revision. The service's pointer is
  # therefore ignored here — a pipeline-deployed revision (say :11) must never
  # drift-fight Terraform (the ECS API refuses task-def updates on CODE_DEPLOY
  # services anyway: "Use AWS CodeDeploy to trigger a new deployment").
  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

  # Phase 5: CodeDeploy blue/green — same forced-replacement note as city.
  deployment_controller {
    type = "CODE_DEPLOY"
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-user-service" })
}