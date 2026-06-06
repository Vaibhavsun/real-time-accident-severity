resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_eventhub_namespace" "this" {
  name                = "${var.name}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.sku
  capacity            = var.capacity
  tags                = var.tags
}

resource "azurerm_eventhub" "topics" {
  for_each          = toset(var.topics)
  name              = each.value
  namespace_id      = azurerm_eventhub_namespace.this.id
  partition_count   = var.partitions
  message_retention = var.message_retention_days
}

resource "azurerm_eventhub_namespace_authorization_rule" "producer" {
  name                = "${var.name}-producer"
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = azurerm_resource_group.this.name
  listen              = true
  send                = true
  manage              = false
}
