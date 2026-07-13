output "github_actions_role_arn" {
  description = "Put this into GitHub repo secret AWS_ROLE_ARN (CI/CD pipeline)."
  value       = aws_iam_role.github_actions.arn
}

output "github_terraform_role_arn" {
  description = "Put this into GitHub repo secret AWS_TF_ROLE_ARN (infra pipeline)."
  value       = aws_iam_role.github_terraform.arn
}
