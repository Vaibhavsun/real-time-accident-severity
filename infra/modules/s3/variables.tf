variable "bucket_name" {
  description = "Globally unique S3 bucket name"
  type        = string
}

variable "versioning_enabled" {
  description = "Enable S3 versioning"
  type        = bool
  default     = true
}

variable "prefixes" {
  description = "Logical folder prefixes to create inside the bucket"
  type        = list(string)
  default     = ["raw", "processed", "checkpoints", "logs"]
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to empty + delete the bucket (incl. all versions)"
  type        = bool
  default     = true
}
