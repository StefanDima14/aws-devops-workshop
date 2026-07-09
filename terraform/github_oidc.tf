# -----------------------------------------------------------------------------
# GITHUB ACTIONS OIDC — lets the pipeline assume an AWS role with NO stored
# access keys. GitHub presents a short-lived OIDC token; AWS trusts it only for
# your specific repo. This is the modern, secure way to do CI/CD auth.
#
# After `terraform apply`, put the value of output `github_actions_role_arn`
# into your GitHub repo secret named AWS_ROLE_ARN.
# -----------------------------------------------------------------------------

variable "github_repo" {
  description = "GitHub repo in 'owner/name' form, e.g. 'stefan/aws-devops-workshop'."
  type        = string
}

data "aws_caller_identity" "current" {}

# The OIDC identity provider for GitHub Actions (one per account).
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Name = "${local.name}-github-oidc" }
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restrict to your repo on any branch. Tighten to :ref:refs/heads/main if desired.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = { Name = "${local.name}-github-actions" }
}

# Permissions the pipeline needs: push to ECR + send SSM commands to the box.
data "aws_iam_policy_document" "github_permissions" {
  # ECR: auth + push/pull.
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"] # GetAuthorizationToken cannot be resource-scoped.
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # SSM: run the deploy command on our instance.
  statement {
    sid    = "SSMSendCommand"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }

  # SSM Parameter Store: the deploy job reads the video bucket/key that
  # Terraform published (avoids hardcoding the random bucket suffix in CI).
  statement {
    sid    = "SSMReadVideoParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name}/video/*",
    ]
  }

  # Read-only helpers used by the pipeline to find the instance.
  statement {
    sid    = "DescribeHelpers"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${local.name}-github-actions-policy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_permissions.json
}

output "github_actions_role_arn" {
  description = "Put this into GitHub repo secret AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}
