terraform {
  # 1.10 for S3 native state locking, which is what use_lockfile below asks for.
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # Partial configuration: bucket and region come from CI, because the bucket
  # belongs to whoever is deploying and an account's bucket name does not belong
  # in a public repository. State has to be remote for CI to apply at all — with
  # local state every run starts from nothing and tries to create what already
  # exists. `terraform init -backend=false` in the validate job is unaffected.
  backend "s3" {
    key          = "stride-lite/terraform.tfstate"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

# us-east-1 because it is the cheapest, which is the stated priority, and because
# the reason to prefer eu-west-1 turned out to be much weaker than it sounded.
#
# The archives live in s3://openbus-stride-public in eu-west-1, so eu-west-1
# reads them for free. Measured, that archive is 13.2 MiB per hour of SIRI —
# 9.3 GiB a month, about 14 GB with GTFS. Even at the internet rate that is under
# $1.30 a month, against $10.06 a month more for the same instance and disk in
# eu-west-1. The courtesy argument is the real one and it is small: S3 transfer
# out is billed to the bucket's owner, so reading across regions costs Hasadna
# roughly $0.30 a month that same-region reads cost them nothing.
#
# What it costs us is latency on a CloudFront cache miss, since the origin is
# then in Virginia rather than Ireland. CloudFront serves from an edge near the
# viewer and the frontend's query strings repeat under a 300 s TTL, so that is a
# minority of requests — but it is not measured from Israel, and it is the reason
# this is a variable.
variable "region" {
  type    = string
  default = "us-east-1"
}

# t4g.large rather than m7g.large: the same 2 vCPU and 8 GiB for $49.06 a month
# instead of $59.57. It is burstable, and the measurements say that is free here —
# ingest and enrichment together cost 14.7 s per hour of feed, which even on two
# vCPUs is a duty cycle of a couple of percent against a 30% baseline. The spikes
# are the 6-hourly aggregate rebuild at 92 s and the daily GTFS load, and CPU
# credits are for exactly that.
#
# 8 GiB is a floor and not a preference, which is why this does not go smaller
# even though $24 a month is on the table. Typical queries peak under 25 MB, but
# an unfiltered /siri_rides/list joins three large tables and was measured
# failing at a 4 GiB ceiling with MEMORY_LIMIT_EXCEEDED — production answers that
# call, so a 4 GiB box would turn a slower endpoint into a 500 and break the one
# acceptance criterion this project has.
variable "instance_type" {
  type    = string
  default = "t4g.large"
}

# 350 and not 400, and not 300. Measured: the served database is 243.65 GiB now,
# and the backfill still running will add about 34 GiB (152 days at 12.15M rows
# and 18.37 bytes a row), so roughly 278 GiB in use. 300 GB is 279.4 GiB usable,
# which is full on day one and leaves nothing for a merge to work in. 350 GB
# leaves about 48 GiB, which is sixteen months at the measured +36 GiB a year,
# and costs $28 a month against $32.
#
# gp3 grows online without downtime, so sizing for a year and growing later is
# strictly cheaper than sizing for three.
variable "data_volume_gb" {
  type    = number
  default = 350
}

variable "branch" {
  description = "Branch of NoamGaash/stride-lite the instance bootstraps from."
  type        = string
  default     = "main"
}

variable "budget_usd" {
  description = "Monthly spend that triggers an alert. The project's own target is 150."
  type        = number
  default     = 150
}

# Defaulted and not sensitive, at the owner's explicit request: the address is
# public and he would rather the plan be readable than the field be redacted.
# The cost is that a published address gets scraped; that was his call to make.
variable "budget_email" {
  description = "Where the budget alert goes."
  type        = string
  default     = "noam.gaash@gmail.com"
}

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

resource "aws_security_group" "api" {
  name        = "stride-lite-api"
  description = "stride-lite: public API in, nothing else"

  ingress {
    description = "API"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ClickHouse reads the public archive with NOSIGN, so the instance needs no S3
# credentials at all. The role exists only for SSM access.
resource "aws_iam_role" "instance" {
  name = "stride-lite-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "stride-lite-instance"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "app" {
  ami                  = data.aws_ami.al2023_arm.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.instance.name
  security_groups      = [aws_security_group.api.name]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data                   = templatefile("${path.module}/bootstrap.sh", { branch = var.branch })
  user_data_replace_on_change = false

  tags = {
    Name    = "stride-lite"
    Project = "stride-lite"
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.app.availability_zone
  size              = var.data_volume_gb

  # EBS grows in place and never shrinks. Raising data_volume_gb is an online
  # modify with no downtime; LOWERING it is a replacement, and a replacement of
  # this volume is the loss of the whole database and the fifteen hours of
  # backfill that filled it. There is no undo and no warning beyond the plan.
  #
  # So this is here to turn that mistake into an error. For a deliberate
  # teardown, remove the block, apply, then destroy.
  lifecycle {
    prevent_destroy = true
  }
  type      = "gp3"
  encrypted = true

  tags = {
    Name    = "stride-lite-data"
    Project = "stride-lite"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}

# Egress volume is the single unknown this design cannot measure locally, so
# the API is fronted by CloudFront: it caches the repeated query strings the
# frontend issues, which bounds origin traffic instead of leaving it open-ended.
resource "aws_cloudfront_distribution" "api" {
  enabled = true
  comment = "stride-lite API"

  origin {
    domain_name = aws_instance.app.public_dns
    origin_id   = "api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "api"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # Every endpoint is a GET whose result is a pure function of its query
    # string, so the full query string is the cache key.
    forwarded_values {
      query_string = true
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 300
    max_ttl     = 3600
    compress    = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# The one guard this deployment needs. Availability deliberately has none: the
# SIRI and GTFS requesters write to S3 independently of this node, so the
# database here is a derived cache. Losing it for days costs compute to rebuild
# and nothing else, which is why there are no snapshots, no failover and no
# health alarms in this module. Spend is the only thing that cannot be
# recovered after the fact, so spend is the only thing alarmed.
resource "aws_budgets_budget" "monthly" {
  name         = "stride-lite-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_email]
    }
  }
}

output "api_url" {
  value = "https://${aws_cloudfront_distribution.api.domain_name}"
}

output "instance_id" {
  value = aws_instance.app.id
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.api.id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

# CloudFront's free tier means the bill will read zero for egress during a short
# experiment, so the traffic has to be read from CloudWatch and priced by hand.
output "measure_cost_command" {
  value = join(" ", [
    "scripts/measure-cost.py collect",
    "--distribution ${aws_cloudfront_distribution.api.id}",
    "--instance ${aws_instance.app.id}",
    "--days 3 > usage.json && scripts/measure-cost.py price usage.json",
  ])
}
