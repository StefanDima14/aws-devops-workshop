# -----------------------------------------------------------------------------
# ECR — private Docker registry where CI pushes the image and EC2 pulls it.
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # lets `terraform destroy` remove it even with images

  image_scanning_configuration {
    scan_on_push = true # AWS-side vulnerability scan (in addition to Trivy in CI)
  }

  tags = { Name = "${local.name}-ecr" }
}

# Lifecycle policy: keep only the last 10 images to control storage cost.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# -----------------------------------------------------------------------------
# IAM ROLE for the EC2 instance.
# Grants: pull from ECR + write logs + be managed by SSM (browser shell, no SSH).
# Least privilege: only the managed policies needed for those jobs.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-ec2-role" }
}

# Read-only pull access to ECR.
resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM lets you open a shell in the browser (Session Manager) — no SSH keys needed.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}
