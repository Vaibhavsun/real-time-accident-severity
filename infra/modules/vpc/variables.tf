variable "name" {
  description = "VPC name prefix"
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread subnets across (>=2 for MSK)"
  type        = number
  default     = 2
}

variable "create_private_subnets" {
  description = "Also create private subnets (no NAT — useful only with VPC endpoints)"
  type        = bool
  default     = false
}
