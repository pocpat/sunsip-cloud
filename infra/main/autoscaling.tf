# Phase 3 / Step 7 — Auto-scaling (brief: "4 scaling policies (2 out, 2 in) +
# 4 CloudWatch alarms (2 high, 2 low CPU)" against the RUNNING Phase 2
# services).
#
# How the pieces chain (the report story):
#   CloudWatch alarm fires (CPU over threshold)
#     -> calls the scaling policy (arn chained in the alarm's alarm_actions)
#       -> policy applies its step table (add 1 task / remove 1 task)
#         -> Application Auto Scaling changes the ECS service desired_count
#
# Numbers (why each value exists):
#   task size = 0.25 vCPU (256 units), 0.5 GB — see tasks.tf. CPU % is measured
#   against the 0.25 vCPU, so 70% = roughly 0.175 vCPU of real work.
#   scale OUT at >=70% CPU for 2 x 1 min  — act quickly, users are waiting
#   scale IN  at < 30% CPU for 3 x 5 min  — act slowly, never bounce a task
#     (2 min of high CPU is clearly load; 15 min of low CPU is clearly idle)
#   steps: 70-85% adds 1 task; >=85% adds 2 (bad overload jumps faster)
#   min 1 / max 3 tasks per service — scale-out ceiling keeps the
#     worst-case cost near 6 tasks (~$0.60/6h session); scale-in floor 1 is
#     also what keeps the platform always demonstrable.
#   treat_missing_data = notBreaching — "no data is not evidence": missing
#     metrics never scale the platform in either direction.
#
# IAM: none needed — Application Auto Scaling uses its own AWS-managed
# service-linked role, created automatically on first policy registration.
#
# PITFALL (report-worthy): the autoscaler now OWNS desired_count at runtime.
# A later plain `terraform apply` would reset the service to 1 task and
# fight a live scaler — one more reason the runbook applies this file right
# after Phase 2, before any traffic/autoscaling is active.

# ------------------------------------------------------- scalable targets
# Target = the DIMENSION that may change: the service's desired task count.

resource "aws_appautoscaling_target" "city" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.city_experience.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = merge(local.common_tags, { Name = "${var.project_name}-autoscale-city" })
}

resource "aws_appautoscaling_target" "user" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.user_collection.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = merge(local.common_tags, { Name = "${var.project_name}-autoscale-user" })
}

# ------------------------------------------------------- scaling policies
# Brief count: 2 OUT (one per service) + 2 IN (one per service).
# adjustment_type ChangeInCapacity counts WHOLE tasks: scaling_adjustment 1
# = +1 task. The percent-only min_adjustment_magnitude attribute is INVALID
# here — AWS ValidationException; learned live 20 Oct.

resource "aws_appautoscaling_policy" "city_out" {
  name               = "${var.project_name}-city-scale-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.city.resource_id
  scalable_dimension = aws_appautoscaling_target.city.scalable_dimension
  service_namespace  = aws_appautoscaling_target.city.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 180 # wait 3 min between out-steps to see the effect
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0 # 70%..85% of threshold
      metric_interval_upper_bound = 15
      scaling_adjustment          = 1 # +1 task
    }
    step_adjustment {
      metric_interval_lower_bound = 15 # >=85% of threshold (85%+ CPU)
      scaling_adjustment          = 2  # +2 tasks
    }
  }
}

resource "aws_appautoscaling_policy" "city_in" {
  name               = "${var.project_name}-city-scale-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.city.resource_id
  scalable_dimension = aws_appautoscaling_target.city.scalable_dimension
  service_namespace  = aws_appautoscaling_target.city.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300 # 5 min between in-steps - slow down-scaling
    metric_aggregation_type = "Average"

    step_adjustment {
      # alarm already means CPU < 30% (threshold 70 - 40); anything below
      # fires the single "-1 task" step.
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_appautoscaling_policy" "user_out" {
  name               = "${var.project_name}-user-scale-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.user.resource_id
  scalable_dimension = aws_appautoscaling_target.user.scalable_dimension
  service_namespace  = aws_appautoscaling_target.user.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 180
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 15
      scaling_adjustment          = 1
    }
    step_adjustment {
      metric_interval_lower_bound = 15
      scaling_adjustment          = 2
    }
  }
}

resource "aws_appautoscaling_policy" "user_in" {
  name               = "${var.project_name}-user-scale-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.user.resource_id
  scalable_dimension = aws_appautoscaling_target.user.scalable_dimension
  service_namespace  = aws_appautoscaling_target.user.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

# ------------------------------------------------------- CloudWatch alarms
# Namespace AWS/ECS, metric CPUUtilization (basic monitoring, free, no
# Container Insights needed — see ecs.tf). ">= 70" is out; "< 30" is in:
# the in-alarm threshold sits WELL below out (a wide 30-70 band = idle
# middle ground) so one load spike cannot ping-pong tasks.

resource "aws_cloudwatch_metric_alarm" "city_high_cpu" {
  alarm_name          = "${var.project_name}-city-high-cpu"
  alarm_description   = "Scale OUT: city-experience CPU >= 70% for 2 min"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  unit                = "Percent"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.city_experience.name
  }

  # alarm_actions: scale the service + (Phase 4) email the SNS alerts topic.
  alarm_actions = [aws_appautoscaling_policy.city_out.arn, aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Name = "${var.project_name}-alarm-city-high" })
}

resource "aws_cloudwatch_metric_alarm" "city_low_cpu" {
  alarm_name          = "${var.project_name}-city-low-cpu"
  alarm_description   = "Scale IN: city-experience CPU < 30% for 15 min"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 30
  unit                = "Percent"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.city_experience.name
  }

  alarm_actions = [aws_appautoscaling_policy.city_in.arn, aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Name = "${var.project_name}-alarm-city-low" })
}

resource "aws_cloudwatch_metric_alarm" "user_high_cpu" {
  alarm_name          = "${var.project_name}-user-high-cpu"
  alarm_description   = "Scale OUT: user-collection CPU >= 70% for 2 min"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  unit                = "Percent"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.user_collection.name
  }

  alarm_actions = [aws_appautoscaling_policy.user_out.arn, aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Name = "${var.project_name}-alarm-user-high" })
}

resource "aws_cloudwatch_metric_alarm" "user_low_cpu" {
  alarm_name          = "${var.project_name}-user-low-cpu"
  alarm_description   = "Scale IN: user-collection CPU < 30% for 15 min"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 30
  unit                = "Percent"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.user_collection.name
  }

  alarm_actions = [aws_appautoscaling_policy.user_in.arn, aws_sns_topic.alerts.arn]

  tags = merge(local.common_tags, { Name = "${var.project_name}-alarm-user-low" })
}

# ------------------------------------------------------------------ outputs
# Feed the runbook read-back rows (values instead of retyping names).

output "scaling_targets" {
  value = {
    city = aws_appautoscaling_target.city.resource_id
    user = aws_appautoscaling_target.user.resource_id
  }
}

output "scaling_policy_arns" {
  value = {
    city_out = aws_appautoscaling_policy.city_out.arn
    city_in  = aws_appautoscaling_policy.city_in.arn
    user_out = aws_appautoscaling_policy.user_out.arn
    user_in  = aws_appautoscaling_policy.user_in.arn
  }
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.city_high_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.city_low_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.user_high_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.user_low_cpu.alarm_name,
  ]
}