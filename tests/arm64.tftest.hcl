mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "ap-southeast-2"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

mock_provider "random" {}
mock_provider "tls" {}

variables {
  name                            = "test"
  account_name                    = "test"
  instance_types                  = ["t3.medium"]
  vpc_id                          = "vpc-12345678"
  private_subnet_ids              = ["subnet-12345678"]
  public_subnet_ids               = []
  secure_subnet_ids               = []
  certificate_arn                 = ""
  alb                             = false
  create_efs                      = false
  alarm_efs_credits_low_threshold = 0
}

run "disabled_preserves_existing_provider" {
  command = plan

  variables {
    capacity_providers = ["external-provider"]
  }

  assert {
    condition = (
      length(data.aws_ami.arm64) == 0 &&
      length(aws_launch_template.arm64) == 0 &&
      length(aws_autoscaling_group.arm64) == 0 &&
      length(aws_ecs_capacity_provider.arm64) == 0 &&
      length(aws_autoscaling_schedule.arm64_start) == 0 &&
      length(aws_cloudwatch_metric_alarm.arm64_high_cpu) == 0 &&
      output.arm64_capacity_provider_name == ""
    )
    error_message = "ARM64 resources must not be created by default."
  }

  assert {
    condition = (
      aws_autoscaling_group.ecs[0].name == "ecs-test" &&
      aws_autoscaling_group.ecs[0].min_size == 1 &&
      aws_ecs_capacity_provider.ecs_capacity_provider[0].name == "test-capacity-provider" &&
      toset(aws_ecs_cluster_capacity_providers.ecs.capacity_providers) == toset(["test-capacity-provider", "FARGATE", "FARGATE_SPOT", "external-provider"]) &&
      one(aws_ecs_cluster_capacity_providers.ecs.default_capacity_provider_strategy).capacity_provider == "test-capacity-provider" &&
      one(aws_ecs_cluster_capacity_providers.ecs.default_capacity_provider_strategy).base == 1 &&
      one(aws_ecs_cluster_capacity_providers.ecs.default_capacity_provider_strategy).weight == 100
    )
    error_message = "Existing resources, external providers and the default strategy must be preserved."
  }
}

run "enabled_adds_arm64_with_zero_minimum" {
  command = plan

  variables {
    enable_arm64_capacity_provider = true
    arm64_instance_types           = ["t4g.medium", "t4g.large"]
    arm64_asg_max                  = 6
    enable_schedule                = true
    schedule_cron_start            = "0 20 * * *"
    schedule_cron_stop             = "0 10 * * *"
    alarm_sns_topics               = ["arn:aws:sns:ap-southeast-2:123456789012:test"]
    enable_auto_instance_refresh   = true
    managed_termination_protection = true
    asg_protect_from_scale_in      = true
    capacity_providers             = ["external-provider"]
  }

  assert {
    condition = (
      length(data.aws_ami.arm64) == 1 &&
      data.aws_ami.arm64[0].owners == data.aws_ami.amzn[0].owners &&
      one([for filter in data.aws_ami.arm64[0].filter : filter.values if filter.name == "name"]) == one([for filter in data.aws_ami.amzn[0].filter : filter.values if filter.name == "name"]) &&
      one([for filter in data.aws_ami.arm64[0].filter : filter.values if filter.name == "architecture"]) == toset(["arm64"]) &&
      aws_launch_template.arm64[0].instance_type == "t4g.medium" &&
      aws_launch_template.arm64[0].user_data == aws_launch_template.ecs[0].user_data &&
      aws_autoscaling_group.arm64[0].min_size == 0 &&
      aws_autoscaling_group.arm64[0].max_size == 6 &&
      toset([for override in aws_autoscaling_group.arm64[0].mixed_instances_policy[0].launch_template[0].override : override.instance_type]) == toset(["t4g.medium", "t4g.large"]) &&
      length(aws_autoscaling_group.arm64[0].instance_refresh) == 1 &&
      aws_ecs_capacity_provider.arm64[0].auto_scaling_group_provider[0].managed_termination_protection == "ENABLED"
    )
    error_message = "ARM64 must use matching AMI filters, separate instance types and maximum, zero minimum and shared ASG settings."
  }

  assert {
    condition = (
      output.arm64_capacity_provider_name == "test-arm64-capacity-provider" &&
      toset(aws_ecs_cluster_capacity_providers.ecs.capacity_providers) == toset(["test-capacity-provider", "test-arm64-capacity-provider", "FARGATE", "FARGATE_SPOT", "external-provider"]) &&
      length(aws_ecs_cluster_capacity_providers.ecs.default_capacity_provider_strategy) == 1 &&
      one(aws_ecs_cluster_capacity_providers.ecs.default_capacity_provider_strategy).capacity_provider == "test-capacity-provider" &&
      aws_autoscaling_schedule.arm64_start[0].min_size == 0 &&
      aws_autoscaling_schedule.arm64_start[0].desired_capacity == 0 &&
      aws_autoscaling_schedule.arm64_start[0].max_size == 6 &&
      aws_autoscaling_schedule.arm64_stop[0].max_size == 0 &&
      aws_cloudwatch_metric_alarm.arm64_high_cpu[0].dimensions.AutoScalingGroupName == "ecs-test-arm64"
    )
    error_message = "ARM64 must be associated without changing default placement, and optional schedules and alarms must cover it."
  }
}

run "fargate_only_skips_arm64" {
  command = plan

  variables {
    fargate_only                   = true
    enable_arm64_capacity_provider = true
  }

  assert {
    condition = (
      length(data.aws_ami.arm64) == 0 &&
      length(aws_launch_template.arm64) == 0 &&
      length(aws_autoscaling_group.arm64) == 0 &&
      length(aws_ecs_capacity_provider.arm64) == 0 &&
      length(aws_ecs_cluster_capacity_providers.ecs.default_capacity_provider_strategy) == 0 &&
      toset(aws_ecs_cluster_capacity_providers.ecs.capacity_providers) == toset(["FARGATE", "FARGATE_SPOT"])
    )
    error_message = "Fargate-only clusters must not create EC2 capacity providers even when ARM64 is enabled."
  }
}

run "legacy_arm64_primary_is_unchanged" {
  command = plan

  variables {
    architecture   = "arm64"
    instance_types = ["t4g.medium"]
  }

  assert {
    condition = (
      aws_launch_template.ecs[0].instance_type == "t4g.medium" &&
      one([for filter in data.aws_ami.amzn[0].filter : filter.values if filter.name == "architecture"]) == toset(["arm64"]) &&
      length(aws_ecs_capacity_provider.arm64) == 0
    )
    error_message = "Existing single-provider ARM64 configurations must remain supported."
  }
}

run "enabled_requires_instance_types" {
  command = plan

  variables {
    enable_arm64_capacity_provider = true
  }

  expect_failures = [aws_launch_template.arm64]
}

run "enabled_requires_existing_x86_provider" {
  command = plan

  variables {
    enable_arm64_capacity_provider = true
    arm64_instance_types           = ["t4g.medium"]
    architecture                   = "arm64"
  }

  expect_failures = [aws_launch_template.arm64]
}

run "rejects_invalid_maximum" {
  command = plan

  variables {
    arm64_asg_max = 0
  }

  expect_failures = [var.arm64_asg_max]
}
