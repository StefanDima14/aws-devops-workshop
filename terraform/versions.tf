terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ---------------------------------------------------------------------------
  # REMOTE STATE — shared, locked state so the infra pipeline (and your laptop)
  # operate on the same source of truth. This uses PARTIAL configuration: the
  # bucket / table / key are supplied at `terraform init` time, not hardcoded.
  #
  #   1. Create the state bucket + lock table once:  scripts/bootstrap-backend.sh
  #   2. Init with the backend config:
  #        terraform init -backend-config=backend.hcl
  #      (copy backend.hcl.example -> backend.hcl and fill in your bucket name)
  #
  # The CI pipeline passes the same values via -backend-config flags.
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
    }
  }
}
