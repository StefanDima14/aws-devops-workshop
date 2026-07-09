variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name, used to name/tag resources."
  type        = string
  default     = "devops-workshop"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens only."
  }
}

variable "environment" {
  description = "Environment name (dev/stage/prod)."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag value (your name / team)."
  type        = string
  default     = "workshop"
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is Free Tier eligible."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB. Must be >= 30 (the AL2023 AMI snapshot size)."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 30
    error_message = "root_volume_size must be at least 30 GB (the AL2023 AMI snapshot size)."
  }
}

variable "my_ip_cidr" {
  description = <<-EOT
    Your public IP in CIDR form (e.g. "203.0.113.5/32") allowed to SSH.
    Find it with: curl -s https://checkip.amazonaws.com
    Set to "0.0.0.0/0" ONLY if you accept SSH open to the world (not recommended).
  EOT
  type        = string
}

variable "app_port" {
  description = "Port the container/app listens on."
  type        = number
  default     = 8080
}

variable "video_url" {
  description = "Fallback public video URL used only when no S3 bucket/object is available (local dev, first boot)."
  type        = string
  default     = "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4"
}

variable "video_object_key" {
  description = "S3 object key (path) the video is stored under in the bucket."
  type        = string
  default     = "video.mp4"
}

variable "video_source_path" {
  description = <<-EOT
    Local path to a video file to upload to the S3 bucket on `terraform apply`.
    Leave empty ("") to create the bucket now and upload the object yourself later:
      aws s3 cp video.mp4 s3://<bucket>/<key>
    Example: "../assets/video.mp4"
  EOT
  type        = string
  default     = ""
}

variable "presigned_url_expiry" {
  description = "Lifetime (seconds) of the presigned video URL the app generates."
  type        = number
  default     = 3600
}

variable "key_pair_name" {
  description = <<-EOT
    Name of an EXISTING EC2 key pair for SSH access. Create one first with:
    aws ec2 create-key-pair --key-name workshop-key --query 'KeyMaterial' \
      --output text > workshop-key.pem && chmod 400 workshop-key.pem
    Leave empty ("") to skip SSH key assignment.
  EOT
  type        = string
  default     = ""
}
