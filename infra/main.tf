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

# us-east-1 because it is the cheapest, which is the recorded priority
# (README.md §"Who decided what": "Cheapest wins, some performance loss is
# acceptable", which is the line that ruled out eu-west-1 for same-region reads).
# What follows is that decision re-priced against the bulk load, which it did
# not cover, and it survives.
#
# The archives live in s3://openbus-stride-public in eu-west-1, and S3 transfer
# out is billed to the bucket's owner — Hasadna, a non-profit — so the region
# this runs in decides what somebody else pays. Rates from AWS's own price list
# (AWSDataTransfer offer file, fetched 2026-11-07): eu-west-1 to another AWS
# region is $0.02/GB, to the internet $0.09/GB, and the AmazonS3 eu-west-1 offer
# file carries no same-region transfer line at all, so a reader in eu-west-1
# costs the owner nothing but requests ($0.0004 per 1,000 GETs).
#
# Measured by unsigned LIST on 2026-11-07, so no object bytes were moved to
# measure it: the whole SIRI archive is 288,970,717,345 bytes (269.1 GiB) in
# 2,794,246 objects, 2021/04 to 2026/11, and October 2026 alone is 5.37 GiB in
# 44,293 objects — about 7.4 MiB an hour of feed, not the 13.2 MiB this comment
# used to claim. The dump is 154,630,881,726 bytes.
#
# Dollars below treat a GB as 10^9 bytes, which is how the byte counts were
# converted and not something verified against how AWS meters transfer; at 2^30
# every figure is 7% smaller. The larger is quoted.
#
# So, for the whole of it:
#
#   first load, dump + the 162 days after it   $3.66 of transfer and $0.09 of
#                                              requests from us-east-1;
#                                              $0.09 from eu-west-1
#   first load, whole archive instead          $5.78 of transfer, $1.12 of GETs
#   steady-state ingest                        $0.13 a month from us-east-1,
#                                              $0.02 a month from eu-west-1
#   same instance and disk in eu-west-1        $10.06 a month more, to us
#
# $120.72 a year of this project's money against $3.75 of Hasadna's, once, and
# $1.32 a year after that. The one-off is once *ever* and not once per instance:
# scripts/first-load.sh publishes the built database to our own bucket, and every
# later instance restores from there without touching the public bucket at all.
# That is what makes the cheap region defensible rather than merely cheaper.
#
# What us-east-1 costs us is latency on a CloudFront cache miss, since the origin
# is then in Virginia rather than Ireland. The frontend's query strings repeat
# under a 300 s TTL so that is a minority of requests — still not measured from
# Israel, and still the reason this is a variable. `-var region=eu-west-1` moves
# everything, and is the right choice for the one instance that does the public
# rebuild if the $3.66 is worth avoiding.
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
# TEMPORARY, for the first load only, and the next commit on main should put
# `t4g.large` back.
#
# t4g.large is the size this project is costed and argued on, and it is the right
# size to *serve* from. It is the wrong size to build from once: it is burstable,
# 2 vCPU against a 30% baseline, and the first load saturates CPU for hours
# — zstd-decompressing a 155 GB dump, inserting it, backfilling 163 days of
# archive, then materialising four projections. That exhausts the CPU credits and
# then runs at 30% of two cores, which turns a job measured at 14 h on six
# throttled cores into days. It does not fail; it crawls, which is worse, because
# nothing reports it.
#
# c7g.8xlarge is ~$0.97/hour, about $700 a month if it is left here. The budget
# alarm at $150 fires after the fact, not before. Terraform changes this in place
# — stop, modify, start — and the data lives on a separate EBS volume with
# user_data_replace_on_change = false, so shrinking it later keeps the database
# and does not re-run bootstrap. Shrink only once first-load.sh reports done: a
# stop mid-load kills it, and although the stage file in
# /var/lib/clickhouse/first-load.state resumes it, the hours are spent.
# c7g.4xlarge (16 vCPU, 32 GiB), not c7g.8xlarge (32 vCPU): the account's
# On-Demand Standard vCPU quota is 16, and this is the first and only instance
# this project creates, so there is nothing else to share it with. 16 vCPU
# non-burstable is still far ahead of t4g.large for the reason above; it is a
# quota fit, not a cost compromise.
# The data volume already exists in this AZ; pinning the instance to the same
# one is what makes aws_ebs_volume.data's own AZ reference a plan-time literal
# instead of a value that depends on the instance existing. See the comment on
# aws_instance.app.
variable "availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "instance_type" {
  type    = string
  default = "c7g.4xlarge"
}

# 350 and not 400, and not 300. Measured on the local database 2026-11-07:
# 180.43 GiB of base tables and 74.14 GiB of projections, 254.57 GiB served, and
# that is with September and October 2026 still missing — about 10 GiB of
# vehicle locations and their projections, so call a complete history 265 GiB.
# 300 GB is 279.4 GiB usable, which is full on arrival and leaves nothing for a
# merge to work in; 350 GB is 326.0 GiB and leaves about 61 GiB.
#
# How long 61 GiB lasts is now two numbers, not one, because the landing rows
# are kept: the typed tables grow at the measured +36 GiB a year and
# siri_vehicle_location_raw adds 2.80 GiB a month on top (measured: 133.76M rows
# for 2026/08), so about +70 GiB a year. That is ten months, not the sixteen
# this comment used to claim from the typed tables alone.
#
# The first load needs no headroom beyond that figure, which is the one thing
# worth knowing before raising it: scripts/load-from-dump.sh streams, so the
# 144.01 GiB dump is never on the disk. Staging it would need 398 GiB and is not
# a size this volume can be, which is why that script takes a URL.
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

# Our own copy of the built database, and the reason a second instance never
# reads Hasadna's bucket in bulk. 254.57 GiB of S3 Standard is $5.86 a month,
# which takes the bill from $82.55 to $88.41 — 7% for turning a first load of
# days into one of hours and a one-off cost to a non-profit into nothing.
#
# false keeps the bucket out of the account entirely, and then every fresh
# instance rebuilds from public data. That is the reproducible path and it still
# works; it is just the expensive one, and the expense is not ours.
variable "backup_bucket_enabled" {
  description = "Keep a restorable copy of the database in S3, so a fresh instance does not rebuild from the public dump."
  type        = bool
  default     = true
}

# A DNS name for the API, which the frontend needs rather than wants: its
# production CSP allows connect-src https://*.hasadna.org.il and nothing else,
# so a d111111abcdef8.cloudfront.net origin cannot be reached from the deployed
# site at all. Setting this to a name in that zone is what makes the frontend's
# opt-in switchable without touching its CSP.
#
# Empty leaves the distribution on its *.cloudfront.net name, which is what it
# has today and is fine for curl and for a local frontend.
#
# Setting it needs one thing this module cannot do: a CNAME in the hasadna.org.il
# zone, which lives in Cloudflare under hasadna-iac. Terraform requests the
# certificate and then waits for DNS validation, so the apply blocks until the
# validation record exists — `terraform output acm_validation_records` prints it.
variable "api_domain" {
  description = "Public DNS name for the API, e.g. stride-lite.hasadna.org.il. Empty uses the CloudFront default name."
  type        = string
  default     = ""
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

# CloudFront only accepts a certificate from us-east-1, wherever the origin is,
# so the certificate below is created through this provider and everything else
# through the default one.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

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

# ---- our own copy of the database -----------------------------------------
# Named after the account because S3 bucket names are global, the same reason
# the Terraform state bucket is. prevent_destroy for the same reason the data
# volume has it: this is the thing that makes a rebuild an hour instead of days,
# and a `terraform destroy` that takes it with the instance would be the one
# mistake here with no undo.
resource "aws_s3_bucket" "backup" {
  count         = var.backup_bucket_enabled ? 1 : 0
  bucket        = "stride-lite-backup-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "stride-lite-backup"
    Project = "stride-lite"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  count                   = var.backup_bucket_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  count  = var.backup_bucket_enabled ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A role for ClickHouse to assume, rather than keys for it to hold. Measured on
# ClickHouse 26.10: BACKUP/RESTORE TO S3 with only a URL is refused outright
# ("not allowed to use the server's own credentials") unless
# s3_allow_server_credentials_in_user_queries is turned on, while
# extra_credentials(role_arn = …) is allowed with that setting at its default —
# the server's instance profile signs only the STS AssumeRole call, and the
# assumed role's own credentials sign every S3 request. So this deployment keeps
# its no-static-credentials property and does not relax a security setting to do
# it. scripts/backup.sh is the caller.
resource "aws_iam_role" "backup" {
  count = var.backup_bucket_enabled ? 1 : 0
  name  = "stride-lite-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = aws_iam_role.instance.arn }
    }]
  })
}

resource "aws_iam_role_policy" "backup" {
  count = var.backup_bucket_enabled ? 1 : 0
  name  = "stride-lite-backup"
  role  = aws_iam_role.backup[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.backup[0].arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.backup[0].arn
      },
    ]
  })
}

# The instance's own permission is one action on one role, which is the whole of
# its S3 access: the public archive it reads with NOSIGN and needs nothing for.
resource "aws_iam_role_policy" "instance_assume_backup" {
  count = var.backup_bucket_enabled ? 1 : 0
  name  = "stride-lite-assume-backup"
  role  = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.backup[0].arn
      },
      # Listing, and only listing. scripts/first-load.sh asks whether a backup is
      # there before trying to restore one, because the alternative is reading a
      # failed RESTORE's exit code and guessing whether it means "absent" or
      # "broken" — and guessing wrong either loops or starts a two-day rebuild.
      # On the first instance ever the bucket is empty and the answer is no.
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.backup[0].arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "stride-lite-instance"
  role = aws_iam_role.instance.name
}

# Pinned, not left for AWS to pick at launch: aws_ebs_volume.data below reads
# this instance's AZ, and while the instance exists that is a known value, but
# while it does not (replacement, or a manual terminate) it is "known after
# apply" — which does not match the volume's actual, already-fixed AZ, and
# Terraform plans to replace the volume to chase it. That plan is what
# aws_ebs_volume.data's own prevent_destroy caught, rather than the volume
# itself being destroyed. Pinning this makes the reference a literal at plan
# time regardless of whether the instance currently exists, so recreating the
# instance can never again threaten the volume's config.
resource "aws_instance" "app" {
  ami                  = data.aws_ami.al2023_arm.id
  instance_type        = var.instance_type
  availability_zone    = var.availability_zone
  iam_instance_profile = aws_iam_instance_profile.instance.name
  security_groups      = [aws_security_group.api.name]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/bootstrap.sh", {
    branch = var.branch
    region = var.region
    # The trailing slash matters: ClickHouse treats the URL as a directory for
    # the backup's own files, and without it the backup is one object named
    # after the prefix.
    backup_url      = var.backup_bucket_enabled ? "s3://${aws_s3_bucket.backup[0].id}/full/" : ""
    backup_role_arn = var.backup_bucket_enabled ? aws_iam_role.backup[0].arn : ""
  })
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

# ---- the API's own name ----------------------------------------------------
# us_east_1 whatever var.region is: CloudFront reads certificates from there and
# nowhere else.
#
# DNS validation and not email, because the zone is managed as code in
# hasadna-iac and a person clicking a link is not. The record to create is in
# the acm_validation_records output; the validation resource below then waits
# for it, so `terraform apply` sits there until somebody adds it. That is the
# intended shape — the alternative is an apply that succeeds and a distribution
# that serves the wrong certificate.
resource "aws_acm_certificate" "api" {
  provider          = aws.us_east_1
  count             = var.api_domain == "" ? 0 : 1
  domain_name       = var.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name    = "stride-lite-api"
    Project = "stride-lite"
  }
}

resource "aws_acm_certificate_validation" "api" {
  provider        = aws.us_east_1
  count           = var.api_domain == "" ? 0 : 1
  certificate_arn = aws_acm_certificate.api[0].arn

  timeouts {
    create = "60m"
  }
}

# Egress volume is the single unknown this design cannot measure locally, so
# the API is fronted by CloudFront: it caches the repeated query strings the
# frontend issues, which bounds origin traffic instead of leaving it open-ended.
resource "aws_cloudfront_distribution" "api" {
  enabled = true
  comment = "stride-lite API"
  aliases = var.api_domain == "" ? [] : [var.api_domain]

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

  # Without an alias there is nothing to certify but the *.cloudfront.net name,
  # which CloudFront's own certificate already covers.
  dynamic "viewer_certificate" {
    for_each = var.api_domain == "" ? [1] : []
    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.api_domain == "" ? [] : [1]
    content {
      acm_certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn
      ssl_support_method  = "sni-only"
      # 2021 and not the default: the default is TLSv1, and nothing that reads
      # this API is older than a browser that speaks 1.2.
      minimum_protocol_version = "TLSv1.2_2021"
    }
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
  value = "https://${var.api_domain == "" ? aws_cloudfront_distribution.api.domain_name : var.api_domain}"
}

# What the frontend can actually be pointed at. Until api_domain is set this is
# a *.cloudfront.net name, and the deployed frontend's CSP allows connect-src
# https://*.hasadna.org.il only — so the opt-in cannot be switched on with this
# value, whatever is in the variable.
output "api_origin_url" {
  value = "https://${aws_cloudfront_distribution.api.domain_name}"
}

# The CNAME somebody with access to the hasadna.org.il zone has to create, in
# Cloudflare, DNS-only rather than proxied: proxying a name that CloudFront
# already serves adds a second CDN in front of the first.
#
#   <name> CNAME <value>      the validation record, from ACM
#   <api_domain> CNAME <the api_origin_url host>
output "acm_validation_records" {
  value = var.api_domain == "" ? [] : [
    for o in aws_acm_certificate.api[0].domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}

output "backup_url" {
  description = "Where scripts/backup.sh saves and restores the database. Empty when backup_bucket_enabled is false."
  value       = var.backup_bucket_enabled ? "s3://${aws_s3_bucket.backup[0].id}/full/" : ""
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
