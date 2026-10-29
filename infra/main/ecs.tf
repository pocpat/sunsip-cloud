# Phase 2 Step 5b — Container platform (brief section B): ONE Fargate cluster
# hosting both microservices. Cluster itself is free (you pay per TASK, not
# per cluster) - the two task definitions + services arrive in Step 5c.
#
# Fargate = serverless containers: AWS runs the EC2 worker fleet invisibly,
# we declare only CPU/memory per task. Container Insights stays OFF (free
# basic CloudWatch metrics still work; Insights bills separately).

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # cost guard - basic metrics still flow to CloudWatch
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-cluster" })
}

# ------------------------------------------------------------------ outputs

output "ecs_cluster_id" {
  description = "Cluster the Step 5c services and Step 6 deployments attach to"
  value       = aws_ecs_cluster.main.id
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.main.arn
}