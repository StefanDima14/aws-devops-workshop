# -----------------------------------------------------------------------------
# BOOTSTRAP STACK — the identity plumbing that lets GitHub Actions talk to AWS.
#
# This lives in its own state, separate from the workload (../), because the
# infra pipeline assumes the role defined here. If these roles were part of the
# workload state, `terraform destroy` would delete the credentials it is using
# halfway through the run — and no later `apply` could authenticate to rebuild.
#
# Apply this ONCE, from your laptop, with admin credentials. It is not managed by
# any pipeline. The workload stack can then be created and destroyed freely.
# -----------------------------------------------------------------------------

locals {
  name = "${var.project_name}-${var.environment}"

  # The workload stack names its ECR repo exactly "<project>-<env>" (see
  # ../ecr_iam.tf). We rebuild the ARN from that convention rather than reading
  # the workload state, so the two stacks stay independent — and so this policy
  # remains valid across a destroy/recreate of the repo.
  ecr_repository_arn = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${local.name}"
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# GITHUB ACTIONS OIDC — lets the pipelines assume an AWS role with NO stored
# access keys. GitHub presents a short-lived OIDC token; AWS trusts it only for
# your specific repo. This is the modern, secure way to do CI/CD auth.
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# ROLE 1 — the CI/CD pipeline (.github/workflows/cicd.yml). Builds the image,
# pushes it to ECR, and deploys it to EC2 via SSM. Secret: AWS_ROLE_ARN.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = { Name = "${local.name}-github-actions" }
}

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
    resources = [local.ecr_repository_arn]
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

  # SSM Parameter Store: the deploy job reads the video bucket/key that the
  # workload stack published (avoids hardcoding the random bucket suffix in CI).
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
      "ssm:DescribeInstanceInformation",
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

# -----------------------------------------------------------------------------
# ROLE 2 — the INFRASTRUCTURE pipeline (.github/workflows/infra.yml). It runs
# terraform plan/apply/destroy over IAM, VPC, EC2, S3, ECR and SSM, so it needs
# broad permissions. Secret: AWS_TF_ROLE_ARN.
#
# We attach AdministratorAccess for the workshop. In production you would scope
# this down to exactly the services your stack manages, gate `apply` behind a
# GitHub Environment with required reviewers, or run it from a dedicated
# automation account.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "github_terraform" {
  name               = "${local.name}-github-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = { Name = "${local.name}-github-terraform" }
}

resource "aws_iam_role_policy_attachment" "github_terraform_admin" {
  role       = aws_iam_role.github_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
