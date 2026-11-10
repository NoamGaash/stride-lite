# A new Amazon Linux release must not replace the running node.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

run "first_apply" {
  override_data {
    target = data.aws_ami.al2023_arm
    values = { id = "ami-00000000000000001" }
  }
}

run "after_a_new_ami_is_released" {
  command = plan
  override_data {
    target = data.aws_ami.al2023_arm
    values = { id = "ami-00000000000000002" }
  }
  assert {
    condition     = aws_instance.app.ami == "ami-00000000000000001"
    error_message = "a newer AMI would replace the instance"
  }
}
