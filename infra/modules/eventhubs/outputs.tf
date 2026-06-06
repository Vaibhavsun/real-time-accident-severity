output "namespace_name" {
  value       = azurerm_eventhub_namespace.this.name
  description = "Event Hubs namespace name (globally unique)"
}

output "bootstrap_server" {
  value       = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net:9093"
  description = "Kafka bootstrap server endpoint (SASL_SSL on :9093)"
}

output "connection_string" {
  value       = azurerm_eventhub_namespace_authorization_rule.producer.primary_connection_string
  description = "SASL/PLAIN password for the producer (use literal string '$ConnectionString' as username)"
  sensitive   = true
}

output "topics" {
  value       = [for t in azurerm_eventhub.topics : t.name]
  description = "Event hub (Kafka topic) names created"
}

output "resource_group_name" {
  value       = azurerm_resource_group.this.name
  description = "Azure resource group containing the namespace"
}
