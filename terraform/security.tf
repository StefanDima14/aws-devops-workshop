# -----------------------------------------------------------------------------
# SECURITY GROUP (the instance firewall)
# - Port 80 open to the world so students can browse the app.
# - SSH (22) restricted to your IP only (least privilege).
# -----------------------------------------------------------------------------

resource "aws_security_group" "web" {
  name        = "${local.name}-web-sg"
  description = "Allow HTTP from anywhere and SSH from my IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH only from your IP. Only created when a key pair is provided.
  dynamic "ingress" {
    for_each = var.key_pair_name != "" ? [1] : []
    content {
      description = "SSH from my IP"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.my_ip_cidr]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-web-sg" }
}
