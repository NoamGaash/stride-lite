# A node that stops answering is rebooted, and one whose host fails is moved to
# new hardware. Either way it is the same instance: the Elastic IP the Ministry
# allowlists and the data volume stay attached. Inside the node, a requester run
# that hangs is ended by its unit's timeout and the next one starts fresh;
# these handle the node itself.
#
# Evaluation periods per AWS's own advice: three minutes for reboot and two for
# recover, so the two never race. Missing data is not a failure, because these
# metrics can drop out on a healthy instance.

resource "aws_cloudwatch_metric_alarm" "reboot_when_unresponsive" {
  alarm_name          = "stride-lite-reboot-when-unresponsive"
  alarm_description   = "The instance status check failed for three minutes: reboot it."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.app.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "missing"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:reboot"]
}

resource "aws_cloudwatch_metric_alarm" "recover_when_host_fails" {
  alarm_name          = "stride-lite-recover-when-host-fails"
  alarm_description   = "The system status check failed for two minutes: recover onto new hardware."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.app.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "missing"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:recover"]
}
