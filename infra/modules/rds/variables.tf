variable "name" {
  description = "Name prefix for RDS resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where RDS lives"
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR allowed inbound on 5432"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the DB subnet group (>=2 across distinct AZs)"
  type        = list(string)
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "dashboard"
}

variable "db_username" {
  description = "Master DB username"
  type        = string
  default     = "dashboard_admin"
}

variable "db_password" {
  description = "Master DB password (also stored in Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "instance_class" {
  description = "RDS instance class. db.t3.micro is Free-Tier-eligible."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "Postgres engine version"
  type        = string
  default     = "16.3"
}

variable "extra_ingress_cidrs" {
  description = "Additional CIDRs allowed inbound on 5432 (e.g. your laptop for psql). Empty list = VPC only."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
