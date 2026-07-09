output "app_url" {
  description = "Open this in your browser once the pipeline has deployed."
  value       = "http://${aws_eip.web.public_ip}"
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance (used by the CI/CD pipeline)."
  value       = aws_eip.web.public_ip
}

output "instance_id" {
  description = "EC2 instance ID (used by SSM in the pipeline)."
  value       = aws_instance.web.id
}

output "ecr_repository_url" {
  description = "ECR repo URL the pipeline pushes to."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  description = "ECR repo name."
  value       = aws_ecr_repository.app.name
}

output "aws_region" {
  description = "Region everything is deployed in."
  value       = var.aws_region
}

output "video_bucket_name" {
  description = "Private S3 bucket that stores the app's video. Upload with: aws s3 cp video.mp4 s3://<this>/video.mp4"
  value       = aws_s3_bucket.video.bucket
}

output "video_object_key" {
  description = "Object key the app reads the video from."
  value       = var.video_object_key
}
