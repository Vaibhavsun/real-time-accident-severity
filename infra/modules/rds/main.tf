resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = "${var.name}-subnets" })
}

locals {
  # VPC CIDR is always allowed (producer EC2 inside VPC).
  # extra_ingress_cidrs covers everything else (laptop IP, 0.0.0.0/0 for Glue, etc.).
  # distinct() dedupes so AWS doesn't reject "same permission twice".
  rds_ingress_cidrs = distinct(concat([var.vpc_cidr_block], var.extra_ingress_cidrs))
}

resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Postgres ingress for ${var.name}"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = local.rds_ingress_cidrs
    content {
      description = "Postgres from ${ingress.value}"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-sg" })
}

resource "aws_db_instance" "this" {
  identifier              = var.name
  engine                  = "postgres"
  engine_version          = var.engine_version
  instance_class          = var.instance_class
  allocated_storage       = var.allocated_storage
  storage_type            = "gp3"
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  port                    = 5432
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.this.id]
  publicly_accessible     = true
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 1
  apply_immediately       = true
  tags                    = merge(var.tags, { Name = var.name })
}

resource "aws_secretsmanager_secret" "pg" {
  name                    = "${var.name}-pg-credentials"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "pg" {
  secret_id = aws_secretsmanager_secret.pg.id
  secret_string = jsonencode({
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    db       = var.db_name
    user     = var.db_username
    password = var.db_password
  })
}
