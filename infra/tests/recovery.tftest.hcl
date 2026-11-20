# The node reboots when it stops answering and moves when its host fails, as the
# same instance; and the requester can add snapshots to its bucket and do nothing else.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_instance" {
    defaults = { id = "i-0123456789abcdef0", public_dns = "ec2-1-1-1-1.compute-1.amazonaws.com" }
  }
  mock_resource "aws_eip" {
    defaults = { public_dns = "ec2-2-2-2-2.compute-1.amazonaws.com" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::openbus-mot-archive" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

override_data {
  target = data.aws_ami.al2023_arm
  values = { id = "ami-00000000000000001" }
}

run "recovery" {
  assert {
    condition     = aws_cloudwatch_metric_alarm.reboot_when_unresponsive.alarm_actions == toset(["arn:aws:automate:${var.region}:ec2:reboot"])
    error_message = "an unresponsive node is not rebooted"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.recover_when_host_fails.alarm_actions == toset(["arn:aws:automate:${var.region}:ec2:recover"])
    error_message = "a node whose host fails is not recovered"
  }
  assert {
    condition = alltrue([
      for a in [aws_cloudwatch_metric_alarm.reboot_when_unresponsive, aws_cloudwatch_metric_alarm.recover_when_host_fails] :
      a.dimensions["InstanceId"] == "i-0123456789abcdef0"
    ])
    error_message = "an alarm watches some other instance"
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.reboot_when_unresponsive.evaluation_periods != aws_cloudwatch_metric_alarm.recover_when_host_fails.evaluation_periods
    error_message = "reboot and recover evaluate over the same period, which AWS says makes them race"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.instance_mot_archive_siri.policy).Statement[0].Action == "s3:PutObject"
    error_message = "the instance may do more to the archive's SIRI than add to it"
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.instance_mot_archive_gtfs.policy).Statement[0].Action) == toset(["s3:PutObject", "s3:AbortMultipartUpload"])
    error_message = "the instance may do more to the archive's GTFS than add to it"
  }
}
