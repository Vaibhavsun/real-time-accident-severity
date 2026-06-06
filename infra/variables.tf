variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for resource names"
  type        = string
  default     = "accident-severity"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC created by this stack"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread subnets across (>=2 required for MSK)"
  type        = number
  default     = 2
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH into the EC2 instance"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "azure_subscription_id" {
  description = "Azure subscription ID where Event Hubs (Kafka) will be created. Run `az account show --query id -o tsv` to find yours."
  type        = string
}

variable "azure_location" {
  description = "Azure region for Event Hubs (e.g. eastus, westus2, centralindia)"
  type        = string
  default     = "eastus"
}

variable "eventhub_sku" {
  description = "Event Hubs namespace SKU. Must be Standard or Premium for the Kafka surface (Basic does NOT support Kafka)."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Standard", "Premium"], var.eventhub_sku)
    error_message = "eventhub_sku must be Standard or Premium (Basic doesn't support Kafka)."
  }
}

variable "eventhub_partitions" {
  description = "Partitions per event hub (topic). 2-32 for Standard."
  type        = number
  default     = 4
}

variable "producer_rate" {
  description = "Producer messages/sec per stream. 0 = unthrottled (will saturate Standard tier 1 TU)."
  type        = number
  default     = 500
}

variable "producer_max_records" {
  description = "Producer max records per stream before it stops. 0 = stream the whole CSV. Default keeps the first apply quick and cheap."
  type        = number
  default     = 20000
}

# ----------------------- RDS Postgres (dashboard sink) ------------------------
variable "rds_db_name" {
  description = "Initial Postgres database name"
  type        = string
  default     = "dashboard"
}

variable "rds_username" {
  description = "Postgres master username"
  type        = string
  default     = "dashboard_admin"
}

variable "rds_password" {
  description = "Postgres master password. Set in terraform.tfvars or via TF_VAR_rds_password."
  type        = string
  sensitive   = true
}

variable "rds_instance_class" {
  description = "RDS instance class (db.t3.micro = Free Tier)"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_extra_ingress_cidrs" {
  description = "Extra CIDRs allowed to reach RDS:5432 (e.g. your laptop for psql). Empty = VPC only."
  type        = list(string)
  default     = []
}

# ----------------------- Glue Streaming --------------------------------------
variable "glue_worker_type" {
  description = "Glue worker type per job"
  type        = string
  default     = "G.1X"
}

variable "glue_number_of_workers" {
  description = "Workers per Glue streaming job (minimum 2)"
  type        = number
  default     = 2
}

variable "ml_train_schedule_cron" {
  description = "Cron expression (Glue format) for retraining the severity classifier"
  type        = string
  default     = "cron(0/15 * * * ? *)" # every 15 minutes
}
