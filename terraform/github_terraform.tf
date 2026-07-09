# -----------------------------------------------------------------------------
# GITHUB ACTIONS OIDC — role for the INFRASTRUCTURE pipeline (.github/workflows/
# infra.yml). It runs `terraform plan/apply`, which manages IAM, VPC, EC2, S3,
# ECR and SSM — so it needs broad permissions.
#
# We attach AdministratorAccess for the workshop. In production you would scope
# this down to exactly the services/resources your stack manages, gate `apply`
# behind a GitHub Environment with required reviewers, or run it from a dedicated
# automation account. We reuse the same OIDC provider + repo trust policy defined
# in github_oidc.tf (github_assume).
#
# After `terraform apply`, put output `github_terraform_role_arn` into the GitHub
# repo secret AWS_TF_ROLE_ARN.
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

output "github_terraform_role_arn" {
  description = "Put this into GitHub repo secret AWS_TF_ROLE_ARN (infra pipeline)."
  value       = aws_iam_role.github_terraform.arn
}
