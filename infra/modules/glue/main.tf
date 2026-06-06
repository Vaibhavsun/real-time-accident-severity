locals {
  jobs = {
    accident_kpi_geo              = "job1_accident_kpi_geo.py"
    accident_conditions           = "job2_accident_conditions.py"
    accident_hotspots             = "job3_accident_hotspots.py"
    vehicle_profile               = "job4_vehicle_profile.py"
    accident_vehicle_demographics = "job5_accident_vehicle_join.py"
  }

  shared_files = {
    "common.py"  = "common.py"
    "schemas.py" = "schemas.py"
  }
}

# ---------- Event Hubs connection string as a secret ----------
resource "aws_secretsmanager_secret" "eh" {
  name                    = "${var.name_prefix}-eh-connstr"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "eh" {
  secret_id     = aws_secretsmanager_secret.eh.id
  secret_string = var.eh_connection_string
}

# ---------- Upload PySpark scripts to S3 ----------
resource "aws_s3_object" "job_scripts" {
  for_each = local.jobs

  bucket = var.s3_bucket_id
  key    = "${var.scripts_prefix}/${each.value}"
  source = "${var.scripts_local_dir}/${each.value}"
  etag   = filemd5("${var.scripts_local_dir}/${each.value}")
}

resource "aws_s3_object" "shared_files" {
  for_each = local.shared_files

  bucket = var.s3_bucket_id
  key    = "${var.scripts_prefix}/${each.value}"
  source = "${var.scripts_local_dir}/${each.value}"
  etag   = filemd5("${var.scripts_local_dir}/${each.value}")
}

# ---------- IAM role for Glue ----------
data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.name_prefix}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_extra" {
  statement {
    sid     = "S3DataAccess"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/*",
    ]
  }
  statement {
    sid     = "ReadSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      aws_secretsmanager_secret.eh.arn,
      var.pg_secret_arn,
    ]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "glue_extra" {
  name   = "${var.name_prefix}-glue-extra"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_extra.json
}

# ---------- Glue VPC Connection (so streaming jobs can hit RDS in the VPC) ----------
# Glue requires a SG with a self-referencing all-traffic ingress rule on the
# SG attached to the connection — ENIs talk to each other inside it.
resource "aws_security_group" "glue" {
  name        = "${var.name_prefix}-glue-sg"
  description = "Self-referencing SG for Glue VPC connection ENIs"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound (Event Hubs over internet, RDS in VPC, S3 via gateway)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-glue-sg" })
}

resource "aws_security_group_rule" "glue_self_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.glue.id
  source_security_group_id = aws_security_group.glue.id
  description              = "All traffic from itself (required by Glue VPC connection)"
}

# Authorize Glue SG -> RDS SG on 5432
resource "aws_security_group_rule" "rds_from_glue" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = aws_security_group.glue.id
  description              = "Postgres from Glue VPC connection"
}

resource "aws_glue_connection" "rds" {
  name = "${var.name_prefix}-rds-conn"

  connection_type = "NETWORK"

  physical_connection_requirements {
    subnet_id              = var.vpc_subnet_id
    security_group_id_list = [aws_security_group.glue.id]
    availability_zone      = var.vpc_availability_zone
  }

  tags = var.tags
}

# ---------- Streaming jobs ----------
# ---------- ML training job (Python Shell, scheduled per ml_train_schedule_cron) ----------
locals {
  ml_enabled = var.ml_train_script_path != ""
}

resource "aws_s3_object" "ml_train_script" {
  count = local.ml_enabled ? 1 : 0

  bucket = var.s3_bucket_id
  key    = "${var.scripts_prefix}/ml_train.py"
  source = var.ml_train_script_path
  etag   = filemd5(var.ml_train_script_path)
}

resource "aws_glue_job" "ml_train" {
  count = local.ml_enabled ? 1 : 0

  name         = "${var.name_prefix}-ml-train-severity"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"
  max_capacity = 1.0 # Python Shell uses max_capacity (DPU), not workers
  timeout      = 30  # minutes

  command {
    name            = "pythonshell"
    script_location = "s3://${var.s3_bucket_id}/${var.scripts_prefix}/ml_train.py"
    python_version  = "3.9"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--TempDir"                          = "s3://${var.s3_bucket_id}/glue/tmp/"

    "--additional-python-modules" = "scikit-learn==1.5.2,pandas==2.2.3,pyarrow==18.1.0,joblib==1.4.2"

    "--S3_BUCKET"   = var.s3_bucket_id
    "--DATA_PREFIX" = var.output_prefix
    "--MODEL_KEY"   = "models/severity_classifier.joblib"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [aws_s3_object.ml_train_script]
  tags       = var.tags
}

resource "aws_glue_trigger" "ml_train_schedule" {
  count = local.ml_enabled ? 1 : 0

  name     = "${var.name_prefix}-ml-train-every-15m"
  type     = "SCHEDULED"
  schedule = var.ml_train_schedule_cron
  enabled  = true

  actions {
    job_name = aws_glue_job.ml_train[0].name
  }

  tags = var.tags
}

resource "aws_glue_job" "streaming" {
  for_each = local.jobs

  name              = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  role_arn          = aws_iam_role.glue.arn
  glue_version      = var.glue_version
  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = 2880 # 48h — streaming jobs are long-lived; Glue auto-restarts on failure

  # No VPC connection — Glue runs in its managed network and reaches RDS over
  # its public endpoint (RDS still lives in the VPC, just exposed via 5432).
  # connections = [aws_glue_connection.rds.name]

  command {
    name            = "gluestreaming"
    script_location = "s3://${var.s3_bucket_id}/${var.scripts_prefix}/${each.value}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${var.s3_bucket_id}/logs/spark-events/${each.key}/"
    "--TempDir"                          = "s3://${var.s3_bucket_id}/glue/tmp/"

    # Make common.py + schemas.py importable from each job
    "--extra-py-files" = join(",", [
      "s3://${var.s3_bucket_id}/${var.scripts_prefix}/common.py",
      "s3://${var.s3_bucket_id}/${var.scripts_prefix}/schemas.py",
    ])

    # Bring in Postgres JDBC driver
    "--extra-jars"             = "s3://${var.s3_bucket_id}/${var.scripts_prefix}/jars/postgresql-42.7.3.jar"
    "--additional-python-modules" = "psycopg2-binary==2.9.9"

    # Job-specific args
    "--EH_BOOTSTRAP"      = var.eh_bootstrap
    "--EH_SECRET_ID"      = aws_secretsmanager_secret.eh.id
    "--PG_SECRET_ID"      = var.pg_secret_id
    "--S3_OUTPUT_BUCKET"  = var.s3_bucket_id
    "--S3_OUTPUT_PREFIX"  = var.output_prefix
    "--CHECKPOINT_PREFIX" = var.checkpoint_prefix
  }

  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [
    aws_s3_object.job_scripts,
    aws_s3_object.shared_files,
  ]

  tags = var.tags
}
