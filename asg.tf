resource "aws_autoscaling_group" "ecs" {
  count = var.fargate_only ? 0 : 1
  name  = "ecs-${var.name}"

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ecs[0].id
        version            = aws_launch_template.ecs[0].latest_version
      }

      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }

    instances_distribution {
      spot_instance_pools                      = 3
      on_demand_base_capacity                  = var.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = var.on_demand_percentage
    }
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.instance_refresh_config.min_healthy_percentage
      max_healthy_percentage = var.instance_refresh_config.max_healthy_percentage
      skip_matching = var.instance_refresh_config.skip_matching
      instance_warmup = var.instance_refresh_config.instance_warmup
      checkpoint_delay = var.instance_refresh_config.checkpoint_delay
      checkpoint_percentages = var.instance_refresh_config.checkpoint_percentages
    }
    triggers = var.instance_refresh_config.triggers
  }

  vpc_zone_identifier = var.private_subnet_ids

  min_size = var.asg_min
  max_size = var.asg_max

  capacity_rebalance = var.asg_capacity_rebalance

  protect_from_scale_in = var.asg_protect_from_scale_in

  tag {
    key                 = "Name"
    value               = "ecs-node-${var.name}"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  target_group_arns         = var.target_group_arns
  health_check_grace_period = var.autoscaling_health_check_grace_period
  default_cooldown          = var.autoscaling_default_cooldown
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ecs_capacity_provider" "ecs_capacity_provider" {
  count = var.fargate_only ? 0 : 1
  name  = "${var.name}-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs[0].arn
    managed_termination_protection = var.managed_termination_protection && var.asg_protect_from_scale_in ? "ENABLED" : "DISABLED"

    managed_scaling {
      maximum_scaling_step_size = 10
      minimum_scaling_step_size = 1
      status                    = var.managed_scaling ? "ENABLED" : "DISABLED"
      target_capacity           = var.asg_target_capacity
      instance_warmup_period    = var.instance_warmup_period
    }
  }
}
