resource "aws_ecs_cluster" "ecs" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enhanced" : "disabled"
  }

  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

resource "aws_ecs_cluster_capacity_providers" "ecs" {
  cluster_name = aws_ecs_cluster.ecs.name

  dynamic "default_capacity_provider_strategy" {
    for_each = !var.fargate_only ? [1] : []
      content {
        capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider[0].name
        base              = 1
        weight            = 100
      }  
  }

  capacity_providers = concat(compact([
    try(aws_ecs_capacity_provider.ecs_capacity_provider[0].name, ""),
    "FARGATE",
    "FARGATE_SPOT"
  ]), var.capacity_providers)
}
