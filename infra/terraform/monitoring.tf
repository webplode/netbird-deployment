resource "aws_cloudwatch_metric_alarm" "status_check_failed" {
  for_each = local.nodes

  alarm_name          = "${each.value.hostname}-status-check-failed"
  alarm_description   = "EC2 instance or system status check failed for ${each.value.hostname}."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    InstanceId = aws_instance.node[each.key].id
  }

  tags = {
    Name = "${each.value.hostname}-status-check-failed"
    Role = each.value.role
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  for_each = local.nodes

  alarm_name          = "${each.value.hostname}-cpu-high"
  alarm_description   = "Sustained CPU pressure on the user-mandated t4g.small node ${each.value.hostname}."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    InstanceId = aws_instance.node[each.key].id
  }

  tags = {
    Name = "${each.value.hostname}-cpu-high"
    Role = each.value.role
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_credit_low" {
  for_each = local.nodes

  alarm_name          = "${each.value.hostname}-cpu-credit-low"
  alarm_description   = "CPU credit balance is low on burstable node ${each.value.hostname}."
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 20
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    InstanceId = aws_instance.node[each.key].id
  }

  tags = {
    Name = "${each.value.hostname}-cpu-credit-low"
    Role = each.value.role
  }
}
