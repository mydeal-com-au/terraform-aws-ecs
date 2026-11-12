locals {
  arm64_enabled = !var.fargate_only && var.enable_arm64_capacity_provider
}

data "aws_ami" "arm64" {
  count       = local.arm64_enabled ? 1 : 0
  most_recent = true
  owners      = [var.ami_owner]

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_launch_template" "arm64" {
  count         = local.arm64_enabled ? 1 : 0
  name_prefix   = "ecs-${var.name}-arm64-"
  image_id      = data.aws_ami.arm64[0].image_id
  instance_type = try(var.arm64_instance_types[0], null)

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs[0].name
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.instance_volume_size
      encrypted   = true
      volume_type = var.volume_type
      kms_key_id  = var.ebs_key_arn != "" ? var.ebs_key_arn : null
    }
  }

  vpc_security_group_ids = concat([aws_security_group.ecs_nodes.id], var.security_group_ids)
  user_data              = aws_launch_template.ecs[0].user_data
  key_name               = var.ec2_key_enabled ? aws_key_pair.generated_key[0].key_name : null

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = length(var.arm64_instance_types) > 0
      error_message = "arm64_instance_types must contain at least one ARM64 instance type when the ARM64 capacity provider is enabled."
    }

    precondition {
      condition     = var.architecture == "x86_64"
      error_message = "The existing capacity provider must use architecture x86_64 when adding the ARM64 capacity provider."
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge({
      env = var.account_name
    }, var.tags)
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge({
      env = var.account_name
    }, var.tags)
  }
}

resource "aws_autoscaling_group" "arm64" {
  count = local.arm64_enabled ? 1 : 0
  name  = "ecs-${var.name}-arm64"

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.arm64[0].id
        version            = var.enable_auto_instance_refresh ? aws_launch_template.arm64[0].latest_version : "$Latest"
      }

      dynamic "override" {
        for_each = var.arm64_instance_types
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

  dynamic "instance_refresh" {
    for_each = var.enable_auto_instance_refresh ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = var.instance_refresh_config.min_healthy_percentage
        max_healthy_percentage = var.instance_refresh_config.max_healthy_percentage
        skip_matching          = var.instance_refresh_config.skip_matching
        instance_warmup        = var.instance_refresh_config.instance_warmup
        checkpoint_delay       = var.instance_refresh_config.checkpoint_delay
        checkpoint_percentages = var.instance_refresh_config.checkpoint_percentages
      }
      triggers = var.instance_refresh_config.triggers
    }
  }

  vpc_zone_identifier   = var.private_subnet_ids
  min_size              = 0
  max_size              = var.arm64_asg_max
  capacity_rebalance    = var.asg_capacity_rebalance
  protect_from_scale_in = var.asg_protect_from_scale_in

  tag {
    key                 = "Name"
    value               = "ecs-node-${var.name}-arm64"
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

resource "aws_ecs_capacity_provider" "arm64" {
  count = local.arm64_enabled ? 1 : 0
  name  = "${var.name}-arm64-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.arm64[0].arn
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
