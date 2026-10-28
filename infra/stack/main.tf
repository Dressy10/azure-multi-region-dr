# The disposable stack: everything here can be removed by `terraform destroy` and recreated by
# `terraform apply`. State lives in the bootstrap storage account (key stack.tfstate), never here.
#
#   Front Door (global) -> priority 1: UK South Container App   (primary)
#                       -> priority 2: UK West  Container App   (DR, warm standby)
#   Cosmos DB account replicated to both regions with automatic failover.

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
  backend "azurerm" {} # supplied via -backend-config (see scripts/_common.ps1)
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

variable "subscription_id" { type = string }
variable "primary_location" {
  type    = string
  default = "uksouth"
}
variable "dr_location" {
  type    = string
  default = "ukwest"
}
variable "app_image" {
  description = "Stand-in workload for Phase 1: a public, signed image with /healthz and /version. Phase 2 replaces it with a DR-aware service."
  type        = string
  default     = "ghcr.io/dressy10/ledger@sha256:e586f49fbe62efefc527bdf02f9de67533a4fa0ab36fe4b5cd31a15229a50595"
}
variable "cosmos_throughput" {
  description = "Provisioned RU/s on the container. Billed per region replica."
  type        = number
  default     = 400
}
variable "tags" {
  type = map(string)
  default = {
    project = "azure-multi-region-dr"
    owner   = "platform"
    env     = "dr-drill"
  }
}

locals {
  # Deterministic, so a recreated stack gets the same global names (ADR 0002).
  suffix = substr(md5(var.subscription_id), 0, 6)

  regions = {
    primary = { location = var.primary_location, priority = 1, min_replicas = 1 }
    dr      = { location = var.dr_location, priority = 2, min_replicas = 0 }
  }
}

# ---------- Resource groups ----------
resource "azurerm_resource_group" "global" {
  name     = "rg-drproj-global"
  location = var.primary_location
  tags     = var.tags
}

resource "azurerm_resource_group" "region" {
  for_each = local.regions
  name     = "rg-drproj-${each.key}"
  location = each.value.location
  tags     = var.tags
}

# ---------- Per-region compute ----------
# Log Analytics is capped so telemetry can never become the bill.
resource "azurerm_log_analytics_workspace" "region" {
  for_each            = local.regions
  name                = "log-drproj-${each.key}"
  location            = azurerm_resource_group.region[each.key].location
  resource_group_name = azurerm_resource_group.region[each.key].name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.1
  tags                = var.tags
}

resource "azurerm_container_app_environment" "region" {
  for_each                   = local.regions
  name                       = "cae-drproj-${each.key}"
  location                   = azurerm_resource_group.region[each.key].location
  resource_group_name        = azurerm_resource_group.region[each.key].name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.region[each.key].id
  tags                       = var.tags
}

resource "azurerm_container_app" "region" {
  for_each                     = local.regions
  name                         = "ca-drproj-${each.key}"
  resource_group_name          = azurerm_resource_group.region[each.key].name
  container_app_environment_id = azurerm_container_app_environment.region[each.key].id
  revision_mode                = "Single"
  tags                         = var.tags

  template {
    min_replicas = each.value.min_replicas
    max_replicas = 2

    container {
      name   = "app"
      image  = var.app_image
      cpu    = 0.25
      memory = "0.5Gi"

      # The stand-in app echoes APP_VERSION from /version, so a drill can see which region answered.
      env {
        name  = "APP_VERSION"
        value = "${each.key}-${each.value.location}"
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8080
      }
      readiness_probe {
        transport = "HTTP"
        path      = "/healthz"
        port      = 8080
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# ---------- Data: one Cosmos account, two regions, automatic failover ----------
resource "azurerm_cosmosdb_account" "main" {
  name                = "cosmos-drproj-${local.suffix}"
  location            = azurerm_resource_group.global.location
  resource_group_name = azurerm_resource_group.global.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  tags                = var.tags

  automatic_failover_enabled   = true
  local_authentication_enabled = false # Entra ID only: no account keys to leak

  # Session consistency: monotonic reads and read-your-writes for a client, with asynchronous
  # cross-region replication. The RPO this implies is measured in the Phase 3 drills, not assumed.
  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.primary_location
    failover_priority = 0
  }
  geo_location {
    location          = var.dr_location
    failover_priority = 1
  }
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "drdb"
  resource_group_name = azurerm_resource_group.global.name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "ledger" {
  name                  = "ledger"
  resource_group_name   = azurerm_resource_group.global.name
  account_name          = azurerm_cosmosdb_account.main.name
  database_name         = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths   = ["/accountId"]
  partition_key_version = 2
  throughput            = var.cosmos_throughput
}

# ---------- Global entry point: Front Door, priority routing with health probes ----------
resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = "afd-drproj"
  resource_group_name = azurerm_resource_group.global.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = "fde-drproj-${local.suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "app" {
  name                     = "og-app"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id

  # How quickly an origin is declared unhealthy: 3 of the last 4 probes must succeed.
  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 50
  }

  health_probe {
    path                = "/healthz"
    protocol            = "Https"
    request_type        = "GET"
    interval_in_seconds = 10
  }

  restore_traffic_time_to_healed_or_new_endpoint_in_minutes = 1
}

resource "azurerm_cdn_frontdoor_origin" "region" {
  for_each                      = local.regions
  name                          = "origin-${each.key}"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.app.id
  enabled                       = true

  host_name                      = azurerm_container_app.region[each.key].ingress[0].fqdn
  origin_host_header             = azurerm_container_app.region[each.key].ingress[0].fqdn
  https_port                     = 443
  http_port                      = 80
  priority                       = each.value.priority # 1 = primary, 2 = DR
  weight                         = 1000
  certificate_name_check_enabled = true
}

resource "azurerm_cdn_frontdoor_route" "app" {
  name                          = "route-app"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.app.id
  cdn_frontdoor_origin_ids      = [for o in azurerm_cdn_frontdoor_origin.region : o.id]

  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = false # plain HTTP allowed so drill probes can use simple clients
  link_to_default_domain = true
}

# ---------- Outputs ----------
output "frontdoor_url" { value = "https://${azurerm_cdn_frontdoor_endpoint.main.host_name}" }
output "primary_app_fqdn" { value = azurerm_container_app.region["primary"].ingress[0].fqdn }
output "dr_app_fqdn" { value = azurerm_container_app.region["dr"].ingress[0].fqdn }
output "cosmos_endpoint" { value = azurerm_cosmosdb_account.main.endpoint }
output "resource_groups" { value = concat([azurerm_resource_group.global.name], [for r in azurerm_resource_group.region : r.name]) }
