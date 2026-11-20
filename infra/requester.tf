# Where infra/node/systemd/siri-requester.service writes a snapshot every 15
# seconds, at snapshots/YYYY/MM/DD/HH/MM/SS.br: Hasadna's per-minute layout has
# no room for the seconds. Public-read like openbus-stride-public, since the
# snapshots are public data.
# docs/REQUESTER.md is why a second requester exists at all.
resource "aws_s3_bucket" "siri_snapshots" {
  bucket = "openbus-siri-snapshots"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "siri_snapshots" {
  bucket                  = aws_s3_bucket.siri_snapshots.id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "siri_snapshots_public_read" {
  bucket     = aws_s3_bucket.siri_snapshots.id
  depends_on = [aws_s3_bucket_public_access_block.siri_snapshots]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.siri_snapshots.arn}/*"
      },
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.siri_snapshots.arn
      },
    ]
  })
}

# Writing new snapshots, and nothing else: no reads it needs, no deletes.
resource "aws_iam_role_policy" "instance_siri_snapshots" {
  name = "stride-lite-siri-snapshots"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.siri_snapshots.arn}/snapshots/*"
    }]
  })
}
