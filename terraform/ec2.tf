# -----------------------------------------------------------------------------
# EC2 INSTANCE — the box that runs our Docker container.
# We chose EC2 (over ECS/Fargate/App Runner) because it's the easiest service to
# SEE and explain in a workshop: students can SSH in, run `docker ps`, and watch
# the container. Trade-off: you manage the OS. For production, App Runner or ECS
# Fargate removes that toil.
# -----------------------------------------------------------------------------

# Always fetch the latest Amazon Linux 2023 AMI (no hardcoded, stale AMI IDs).
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# user_data runs ONCE on first boot. It installs Docker so the CI/CD pipeline can
# later SSH in and run the container. Rendered from a template so we can inject
# the region/repo without hardcoding.
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    # Install Docker on Amazon Linux 2023.
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user

    # The SSM agent ships with AL2023, but the deploy pipeline can only reach the
    # box once the agent has registered with Systems Manager — so make sure it is
    # enabled and running rather than assuming it.
    dnf install -y amazon-ssm-agent || true
    systemctl enable --now amazon-ssm-agent

    # Install the AWS CLI is already present on AL2023; nothing else needed.
    # The container itself is deployed later by the GitHub Actions pipeline.
    echo "Bootstrap complete. Docker is ready." > /var/log/workshop-bootstrap.log
  EOF
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  user_data              = local.user_data

  # user_data only runs on first boot, so editing the script is only meaningful
  # on a fresh instance: replace the box instead of a no-op stop/start.
  user_data_replace_on_change = true

  # Attach an SSH key only if one was provided.
  key_name = var.key_pair_name != "" ? var.key_pair_name : null

  # Enforce IMDSv2 (blocks a common SSRF-to-credential-theft attack path).
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    # AL2023's AMI snapshot is 30 GB, so the root volume must be >= 30.
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${local.name}-web" }
}

# A stable public IP that survives instance stop/start, so the app URL is fixed.
resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"
  tags     = { Name = "${local.name}-eip" }
}
