# Phase 2 Step 4 — Two PUBLIC Application Load Balancers (brief section A,
# item 3): one per microservice, internet-facing, in the public subnets,
# each with its own target group. Health checks hit /healthz — both services
# already implement it (city-experience returns 200; user-collection proves
# its DynamoDB round-trip before returning 200).

# ------------------------------------------------------ city-experience ALB

resource "aws_lb" "city_experience" {
  name               = "${var.project_name}-alb-city"
  internal           = false # public-facing, as scored
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_city_experience.id]
  subnets            = aws_subnet.city_experience[*].id

  # Cheaper default; HTTPS listener can be added later with a certificate.
  drop_invalid_header_fields = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-alb-city" })
}

resource "aws_lb_target_group" "city_experience" {
  name        = "${var.project_name}-tg-city"
  port        = var.service_ports["city-experience"]
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # Fargate tasks register by IP

  health_check {
    enabled             = true
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-tg-city" })
}

resource "aws_lb_listener" "city_experience_http" {
  load_balancer_arn = aws_lb.city_experience.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.city_experience.arn
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-city-http" })
}

# ------------------------------------------------------ user-collection ALB

resource "aws_lb" "user_collection" {
  name               = "${var.project_name}-alb-user"
  internal           = false # public-facing, as scored
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_user_collection.id]
  subnets            = aws_subnet.user_collection[*].id

  drop_invalid_header_fields = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-alb-user" })
}

resource "aws_lb_target_group" "user_collection" {
  name        = "${var.project_name}-tg-user"
  port        = var.service_ports["user-collection"]
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-tg-user" })
}

resource "aws_lb_listener" "user_collection_http" {
  load_balancer_arn = aws_lb.user_collection.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.user_collection.arn
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-user-http" })
}

# ------------------------------------------------------------------ outputs
# The DNS names are the public URLs the frontend will talk to in production.

output "alb_city_dns" {
  value = aws_lb.city_experience.dns_name
}

output "alb_user_dns" {
  value = aws_lb.user_collection.dns_name
}

output "target_group_arns" {
  value = {
    city = aws_lb_target_group.city_experience.arn
    user = aws_lb_target_group.user_collection.arn
  }
}