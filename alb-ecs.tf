# 1. Create ECR repository
resource "aws_ecr_repository" "repos" {
  for_each             = local.ecs_configs
  name                 = "${local.env}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = true
}

# 2. ECS Cluster
resource "aws_ecs_cluster" "cluster" {
  name = local.cluster_name
}

# 4. ECS Task Definition
resource "aws_ecs_task_definition" "task" {
  for_each                 = local.ecs_configs
  family                   = each.key
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = each.value.task_cpu
  memory                   = each.value.task_memory
  execution_role_arn       = local.ecs_task_execution_role_arn

  container_definitions = jsonencode([
    {
      name  = each.key
      image = "${aws_ecr_repository.repos[each.key].repository_url}:${each.value.image_tag}"
      portMappings = [
        {
          containerPort = each.value.container_port
          hostPort      = each.value.container_port
          protocol      = "tcp"
        }
      ]
      essential = true
    }
  ])

  # Uncomment if you want to use a file for container definitions
  # container_definitions = file("task_definitions/${each.key}.json")
}

# 5. Target Group (for the ECS service)
resource "aws_lb_target_group" "tg" {
  for_each    = local.ecs_configs
  name        = "${each.key}-tg"
  port        = each.value.container_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }
}

resource "aws_lb_listener_rule" "forward_to_ecs" {
  for_each     = local.ecs_configs
  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[each.key].arn
  }

  condition {
    path_pattern {
      values = each.value.path_pattern
    }
  }
}

# 6. ECS Service
resource "aws_ecs_service" "services" {
  for_each                      = local.ecs_configs
  name                          = each.key
  cluster                       = aws_ecs_cluster.cluster.id
  task_definition               = aws_ecs_task_definition.task[each.key].arn
  desired_count                 = 0
  launch_type                   = "FARGATE"
  availability_zone_rebalancing = "ENABLED"
  enable_ecs_managed_tags       = true

  service_connect_configuration {
    enabled = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.private_subnets
    assign_public_ip = false
    security_groups  = [] # Add security group(s) if needed
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg[each.key].arn
    container_name   = each.key
    container_port   = each.value.container_port
  }
}

# 7. (Optional) Link target group to ALB listener rule (if needed)
# This depends on whether you want to create a new listener/rule
# or just use an existing one referring to the target group.

output "ecs_cluster_id" {
  value = aws_ecs_cluster.cluster.id
}
