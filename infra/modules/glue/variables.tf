variable "name_prefix" {
  description = "Name prefix for all Glue resources"
  type        = string
}

variable "scripts_local_dir" {
  description = "Local directory containing the PySpark .py scripts (uploaded to S3)"
  type        = string
}

variable "ml_train_script_path" {
  description = "Path to the ML training script (uploaded to S3 for Glue Python Shell). Empty disables the ML job."
  type        = string
  default     = ""
}

variable "ml_train_schedule_cron" {
  description = "Cron expression for ML retraining (Glue uses cron(...) format). Default: every 15 minutes."
  type        = string
  default     = "cron(0/15 * * * ? *)"
}

variable "s3_bucket_id" {
  description = "S3 bucket id that holds the scripts + outputs + checkpoints"
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  type        = string
}

variable "scripts_prefix" {
  description = "S3 prefix where scripts are uploaded"
  type        = string
  default     = "glue/scripts"
}

variable "output_prefix" {
  description = "S3 prefix for parquet outputs"
  type        = string
  default     = "processed"
}

variable "checkpoint_prefix" {
  description = "S3 prefix for Spark Structured Streaming checkpoints"
  type        = string
  default     = "checkpoints"
}

variable "eh_bootstrap" {
  description = "Event Hubs Kafka bootstrap endpoint (host:9093)"
  type        = string
}

variable "eh_connection_string" {
  description = "Event Hubs connection string (stored in Secrets Manager by this module)"
  type        = string
  sensitive   = true
}

variable "pg_secret_id" {
  description = "Secrets Manager id of the Postgres credentials JSON"
  type        = string
}

variable "pg_secret_arn" {
  description = "Secrets Manager ARN of the Postgres credentials"
  type        = string
}

variable "vpc_subnet_id" {
  description = "Subnet for the Glue VPC connection (must reach RDS in same VPC and have NAT/IGW route for Event Hubs)"
  type        = string
}

variable "vpc_id" {
  description = "VPC id (needed to create the Glue security group)"
  type        = string
}

variable "rds_security_group_id" {
  description = "RDS Postgres SG id. This module adds an ingress rule on it allowing 5432 from the Glue SG."
  type        = string
}

variable "vpc_availability_zone" {
  description = "AZ that vpc_subnet_id sits in (required for Glue Connection)"
  type        = string
}

variable "glue_version" {
  description = "Glue version (4.0 = Spark 3.3, Python 3.10)"
  type        = string
  default     = "4.0"
}

variable "worker_type" {
  description = "Glue worker type (G.1X is cheapest for streaming)"
  type        = string
  default     = "G.1X"
}

variable "number_of_workers" {
  description = "Workers per streaming job (2 is the minimum)"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
