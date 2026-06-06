variable "name" {
  description = "Name prefix for EC2 resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet to launch the instance in"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Defaults to t3.micro (Free Tier eligible). t3.small (2 GB) is more comfortable but not free."
  type        = string
  default     = "t3.micro"
}

variable "private_key_filename" {
  description = "Local path where the generated SSH private key PEM will be written (chmod 0600). Relative paths resolve from the dir where terraform is run."
  type        = string
  default     = "producer-key.pem"
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "extra_security_group_ids" {
  description = "Additional SGs to attach (e.g. to reach MSK)"
  type        = list(string)
  default     = []
}

variable "s3_bucket_arn" {
  description = "S3 bucket ARN to grant instance access to (used only if attach_s3_policy = true)"
  type        = string
  default     = ""
}

variable "attach_s3_policy" {
  description = "Attach an inline S3 policy to the EC2 instance role"
  type        = bool
  default     = false
}

variable "attach_msk_policy" {
  description = "Attach AmazonMSKFullAccess to the instance role"
  type        = bool
  default     = true
}

variable "root_volume_size" {
  description = "Root EBS volume size (GB)"
  type        = number
  default     = 30
}

variable "user_data" {
  description = "Optional cloud-init / user-data script"
  type        = string
  default     = null
}

variable "open_kafka_ui" {
  description = "If true, open ingress on TCP 8080 (Kafka UI) to ssh_allowed_cidrs"
  type        = bool
  default     = false
}
