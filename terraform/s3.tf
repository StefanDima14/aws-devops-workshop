# -----------------------------------------------------------------------------
# S3 — private bucket that stores the video the app streams.
# The bucket is never public: the EC2 instance role can read the object, and
# the app hands the browser a short-lived *presigned* URL. This showcases IAM
# and keeps the least-privilege theme the rest of the workshop teaches.
# -----------------------------------------------------------------------------

# Random suffix so the (globally-unique) bucket name doesn't collide.
resource "random_id" "video_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "video" {
  bucket        = "${local.name}-video-${random_id.video_bucket_suffix.hex}"
  force_destroy = true # workshop convenience: `terraform destroy` even with objects
  tags          = { Name = "${local.name}-video" }
}

# Keep old versions so an accidental overwrite/delete is recoverable.
resource "aws_s3_bucket_versioning" "video" {
  bucket = aws_s3_bucket.video.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt objects at rest (SSE-S3).
resource "aws_s3_bucket_server_side_encryption_configuration" "video" {
  bucket = aws_s3_bucket.video.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Belt-and-braces: block ALL public access. The app uses presigned URLs, so the
# bucket never needs to be public.
resource "aws_s3_bucket_public_access_block" "video" {
  bucket                  = aws_s3_bucket.video.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Optionally upload a local video file at apply time. Leave var.video_source_path
# empty ("") to upload your own object later with:
#   aws s3 cp video.mp4 s3://<bucket>/<key>
resource "aws_s3_object" "video" {
  count        = var.video_source_path != "" ? 1 : 0
  bucket       = aws_s3_bucket.video.id
  key          = var.video_object_key
  source       = var.video_source_path
  etag         = filemd5(var.video_source_path) # re-upload when the file changes
  content_type = "video/mp4"
}

# -----------------------------------------------------------------------------
# Let the EC2 instance role read ONLY objects in the video bucket. This is what
# lets the app presign URLs at runtime without any long-lived credentials.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_s3_read" {
  statement {
    sid       = "ReadVideoObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.video.arn}/*"]
  }
}

resource "aws_iam_role_policy" "ec2_s3_read" {
  name   = "${local.name}-ec2-s3-read"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_s3_read.json
}

# -----------------------------------------------------------------------------
# Publish the bucket name + key to SSM Parameter Store so the DEPLOY pipeline
# can discover them at runtime without hardcoding the random bucket suffix.
# -----------------------------------------------------------------------------
resource "aws_ssm_parameter" "video_bucket" {
  name        = "/${local.name}/video/bucket"
  description = "S3 bucket that stores the app's video."
  type        = "String"
  value       = aws_s3_bucket.video.bucket
}

resource "aws_ssm_parameter" "video_key" {
  name        = "/${local.name}/video/key"
  description = "S3 object key of the app's video."
  type        = "String"
  value       = var.video_object_key
}
