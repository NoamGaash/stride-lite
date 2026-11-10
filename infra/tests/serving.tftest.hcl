# The node serves from the size the project is costed on, cannot run up a CPU
# bill, and keeps its address across the stop and start that resizing it takes.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_instance" {
    defaults = { public_dns = "ec2-1-1-1-1.compute-1.amazonaws.com" }
  }
  mock_resource "aws_eip" {
    defaults = { public_dns = "ec2-2-2-2-2.compute-1.amazonaws.com" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

override_data {
  target = data.aws_ami.al2023_arm
  values = { id = "ami-00000000000000001" }
}

run "serving_node" {
  assert {
    condition     = aws_instance.app.instance_type == "t4g.large"
    error_message = "the node is not back at t4g.large"
  }
  assert {
    condition     = one(aws_instance.app.credit_specification).cpu_credits == "standard"
    error_message = "a burstable node in unlimited mode bills for sustained CPU instead of slowing down"
  }
  assert {
    condition     = one(aws_cloudfront_distribution.api.origin).domain_name == "ec2-2-2-2-2.compute-1.amazonaws.com"
    error_message = "CloudFront follows the instance's own address, which a stop and start changes"
  }
}
