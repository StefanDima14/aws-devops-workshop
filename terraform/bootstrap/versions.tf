terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ---------------------------------------------------------------------------
  # SEPARATE REMOTE STATE from the workload stack (../). Same bucket, different
  # key — see backend.hcl. Keeping these apart is the whole point of this
  # directory: the workload can be destroyed and recreated all day long without
  # ever deleting the roles the pipelines log in with.
  #
  #   terraform init -backend-config=backend.hcl
  # ---------------------------------------------------------------------------
  backend "s3" {
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
      Stack       = "bootstrap"
    }
  }
}
