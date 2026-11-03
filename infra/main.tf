terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

# eu-west-1 because the raw SIRI and GTFS archives already live in
# s3://openbus-stride-public there. Same-region S3 reads are free, which is
# what keeps ingest off the egress bill entirely.
provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "instance_type" {
  description = "Measured peak query memory was under 25 MB, so 8 GB is not a squeeze."
  type        = string
  default     = "m7g.large"
}

variable "data_volume_gb" {
  description = "173 GB measured for siri_vehicle_location plus room to grow."
  type        = number
  default     = 300
}

variable "ssh_cidr" {
  description = "CIDR allowed to reach SSH. Narrow this; it is not defaulted on purpose."
  type        = string
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
  description = "stride-lite: public API in, SSH from an allowed range only"

  ingress {
    description = "API"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
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

  tags = {
    Name    = "stride-lite"
    Project = "stride-lite"
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.app.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true

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

output "api_url" {
  value = "https://${aws_cloudfront_distribution.api.domain_name}"
}

output "instance_id" {
  value = aws_instance.app.id
}
