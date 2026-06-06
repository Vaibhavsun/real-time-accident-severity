variable "name" {
  description = "Name prefix for the resource group + namespace"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "sku" {
  description = "Event Hubs namespace SKU (Standard or Premium — Kafka surface requires non-Basic)"
  type        = string
  default     = "Standard"
}

variable "capacity" {
  description = "Throughput units for the namespace"
  type        = number
  default     = 1
}

variable "topics" {
  description = "Event hub (Kafka topic) names to create"
  type        = list(string)
}

variable "partitions" {
  description = "Partitions per event hub"
  type        = number
  default     = 4
}

variable "message_retention_days" {
  description = "Retention in days for each event hub"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
