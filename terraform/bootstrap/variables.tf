variable "aws_region" {
  description = "AWS region. Must match the workload stack."
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name. Must match the workload stack — resource names are derived from it."
  type        = string
  default     = "devops-workshop"
}

variable "environment" {
  description = "Environment name. Must match the workload stack."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag applied to every resource."
  type        = string
  default     = "stefan"
}

variable "github_repo" {
  description = "GitHub repo in 'owner/name' form — the OIDC trust policy is scoped to it."
  type        = string
}
