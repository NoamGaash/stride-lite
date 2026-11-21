# What this node keeps of the Ministry of Transport's own feeds, public-read like
# Hasadna's openbus-stride-public since all of it is public data:
#   siri/YYYY/MM/DD/HH/MM/SS.br  a SIRI snapshot every 15 seconds, written by
#                                infra/node/systemd/siri-requester.service.
#                                Hasadna's per-minute layout has no room for
#                                the seconds.
# docs/REQUESTER.md is why this node asks the Ministry itself at all.
resource "aws_s3_bucket" "mot_archive" {
  bucket = "openbus-mot-archive"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "mot_archive" {
  bucket                  = aws_s3_bucket.mot_archive.id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "mot_archive_public_read" {
  bucket     = aws_s3_bucket.mot_archive.id
  depends_on = [aws_s3_bucket_public_access_block.mot_archive]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.mot_archive.arn}/*"
      },
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.mot_archive.arn
      },
    ]
  })
}

# Writing new snapshots, and nothing else: no reads it needs, no deletes.
resource "aws_iam_role_policy" "instance_mot_archive_siri" {
  name = "stride-lite-mot-archive-siri"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.mot_archive.arn}/siri/*"
    }]
  })
}
