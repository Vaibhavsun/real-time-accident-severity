locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

module "vpc" {
  source = "./modules/vpc"

  name       = "${local.name_prefix}-vpc"
  cidr_block = var.vpc_cidr
  az_count   = var.az_count
}

module "s3" {
  source      = "./modules/s3"
  bucket_name = "${local.name_prefix}-data"
  prefixes    = ["raw", "processed", "checkpoints", "logs"]
}

module "eventhubs" {
  source = "./modules/eventhubs"

  name       = "${local.name_prefix}-kafka"
  location   = var.azure_location
  sku        = var.eventhub_sku
  topics     = ["accident-raw", "vehicles-raw"]
  partitions = var.eventhub_partitions

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "ec2" {
  source = "./modules/ec2"

  name              = "${local.name_prefix}-producer"
  vpc_id            = module.vpc.vpc_id
  subnet_id         = module.vpc.public_subnet_ids[0]
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  s3_bucket_arn     = module.s3.bucket_arn
  attach_s3_policy  = true
  attach_msk_policy = false
  open_kafka_ui     = true

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    aws_region           = var.aws_region
    bucket               = module.s3.bucket_id
    eh_bootstrap         = module.eventhubs.bootstrap_server
    eh_conn_str          = module.eventhubs.connection_string
    producer_rate        = var.producer_rate
    producer_max_records = var.producer_max_records
  })
}

# -------------------- RDS Postgres (dashboard sink) --------------------
module "rds" {
  source = "./modules/rds"

  name                = "${local.name_prefix}-pg"
  vpc_id              = module.vpc.vpc_id
  vpc_cidr_block      = var.vpc_cidr
  subnet_ids          = module.vpc.public_subnet_ids
  db_name             = var.rds_db_name
  db_username         = var.rds_username
  db_password         = var.rds_password
  instance_class      = var.rds_instance_class
  extra_ingress_cidrs = var.rds_extra_ingress_cidrs

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -------------------- Glue Streaming jobs --------------------
module "glue" {
  source = "./modules/glue"

  name_prefix          = local.name_prefix
  scripts_local_dir    = "${path.module}/glue_scripts"
  s3_bucket_id         = module.s3.bucket_id
  s3_bucket_arn        = module.s3.bucket_arn
  eh_bootstrap         = module.eventhubs.bootstrap_server
  eh_connection_string = module.eventhubs.connection_string

  pg_secret_id  = module.rds.secret_id
  pg_secret_arn = module.rds.secret_arn

  # Glue VPC connection must sit in the same VPC as RDS.
  vpc_id                = module.vpc.vpc_id
  vpc_subnet_id         = module.vpc.public_subnet_ids[0]
  rds_security_group_id = module.rds.security_group_id
  vpc_availability_zone = module.vpc.availability_zones[0]

  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers

  # ML training job — runs every 3 hours via Glue Trigger
  ml_train_script_path   = "${path.module}/../ml_accidental_severity/train.py"
  ml_train_schedule_cron = var.ml_train_schedule_cron

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
