# terraform {
#   required_providers {
#     google = {
#       source  = "hashicorp/google"
#       version = "3.74.0"
#     }
#     google-beta = {
#       source  = "hashicorp/google-beta"
#       version = "3.74.0"
#     }
#   }
# }

provider "google" {
  credentials = file("credentials.json")

  project = "test-project-vazid-s"
  region  = "us-central1"
  zone    = "us-central1-a"
}

provider "google-beta" {
  credentials = file("credentials.json")

  project = "test-project-vazid-s"
  region  = "us-central1"
  zone    = "us-central1-a"
}

locals {
  master_instance_name = var.random_instance_name ? "${var.name}-${random_id.suffix[0].hex}" : var.name

  ip_configuration_enabled = length(keys(var.ip_configuration)) > 0 ? true : false

  ip_configurations = {
    enabled  = var.ip_configuration
    disabled = {}
  }

  databases = { for db in var.additional_databases : db.name => db }
  users     = { for u in var.additional_users : u.name => u }
  iam_users = [for iu in var.iam_user_emails : {
    email         = iu,
    is_account_sa = trimsuffix(iu, "gserviceaccount.com") == iu ? false : true
  }]

  replicas = {
    for x in var.read_replicas : "${var.name}-replica${var.read_replica_name_suffix}${x.name}" => x
  }
  
  retained_backups = lookup(var.backup_configuration, "retained_backups", null)
  retention_unit   = lookup(var.backup_configuration, "retention_unit", null)
}

resource "random_id" "suffix" {
  count = var.random_instance_name ? 1 : 0

  byte_length = 4
}

resource "google_sql_database_instance" "default" {
  provider            = google-beta
  project             = var.project_id
  name                = local.master_instance_name
  database_version    = var.database_version
  region              = var.region
  deletion_protection = var.deletion_protection
  # encryption_key_name = var.encryption_key_name

  settings {
    tier              = var.tier
    activation_policy = var.activation_policy
    availability_type = var.availability_type

    dynamic "backup_configuration" {
      for_each = [var.backup_configuration]
      content {
        binary_log_enabled             = false
        enabled                        = lookup(backup_configuration.value, "enabled", null)
        start_time                     = lookup(backup_configuration.value, "start_time", null)
        location                       = lookup(backup_configuration.value, "location", null)
        point_in_time_recovery_enabled = lookup(backup_configuration.value, "point_in_time_recovery_enabled", false)
        transaction_log_retention_days = lookup(backup_configuration.value, "transaction_log_retention_days", null)

        dynamic "backup_retention_settings" {
          for_each = local.retained_backups != null || local.retention_unit != null ? [var.backup_configuration] : []
          content {
            retained_backups = local.retained_backups
            retention_unit   = local.retention_unit
          }
        }
      }
    }
    dynamic "ip_configuration" {
      for_each = [local.ip_configurations[local.ip_configuration_enabled ? "enabled" : "disabled"]]
      content {
        ipv4_enabled    = lookup(ip_configuration.value, "ipv4_enabled", null)
        private_network = lookup(ip_configuration.value, "private_network", null)
        require_ssl     = lookup(ip_configuration.value, "require_ssl", null)

        dynamic "authorized_networks" {
          for_each = lookup(ip_configuration.value, "authorized_networks", [])
          content {
            expiration_time = lookup(authorized_networks.value, "expiration_time", null)
            name            = lookup(authorized_networks.value, "name", null)
            value           = lookup(authorized_networks.value, "value", null)
          }
        }
      }
    }
    dynamic "insights_config" {
      for_each = var.insights_config != null ? [var.insights_config] : []

      content {
        query_insights_enabled  = true
        query_string_length     = lookup(insights_config.value, "query_string_length", 1024)
        record_application_tags = lookup(insights_config.value, "record_application_tags", false)
        record_client_address   = lookup(insights_config.value, "record_client_address", false)
      }
    }

    disk_autoresize = var.disk_autoresize
    disk_size       = var.disk_size
    disk_type       = var.disk_type
    pricing_plan    = var.pricing_plan
    dynamic "database_flags" {
      for_each = var.database_flags
      content {
        name  = lookup(database_flags.value, "name", null)
        value = lookup(database_flags.value, "value", null)
      }
    }

    user_labels = var.user_labels

    location_preference {
      zone = var.zone
    }

    maintenance_window {
      day          = var.maintenance_window_day
      hour         = var.maintenance_window_hour
      update_track = var.maintenance_window_update_track
    }
  }

  lifecycle {
    ignore_changes = [
      settings[0].disk_size
    ]
  }

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }

  depends_on = [null_resource.module_depends_on]
}

resource "google_sql_database" "default" {
  count      = var.enable_default_db ? 1 : 0
  name       = var.db_name
  project    = var.project_id
  instance   = google_sql_database_instance.default.name
  charset    = var.db_charset
  collation  = var.db_collation
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "google_sql_database" "additional_databases" {
  for_each   = local.databases
  project    = var.project_id
  name       = each.value.name
  charset    = lookup(each.value, "charset", null)
  collation  = lookup(each.value, "collation", null)
  instance   = google_sql_database_instance.default.name
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "random_id" "user-password" {
  keepers = {
    name = google_sql_database_instance.default.name
  }

  byte_length = 8
  depends_on  = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "google_sql_user" "default" {
  count      = var.enable_default_user ? 1 : 0
  name       = var.user_name
  project    = var.project_id
  instance   = google_sql_database_instance.default.name
  password   = var.user_password == "" ? random_id.user-password.hex : var.user_password
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "google_sql_user" "additional_users" {
  for_each   = local.users
  project    = var.project_id
  name       = each.value.name
  password   = coalesce(each.value["password"], random_id.user-password.hex)
  instance   = google_sql_database_instance.default.name
  depends_on = [null_resource.module_depends_on, google_sql_database_instance.default]
}

resource "google_project_iam_member" "iam_binding" {
  for_each = {
    for iu in local.iam_users :
    "${iu.email} ${iu.is_account_sa}" => iu
  }
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member = each.value.is_account_sa ? (
    "serviceAccount:${each.value.email}"
    ) : (
    "user:${each.value.email}"
  )
}

resource "google_sql_user" "iam_account" {
  for_each = {
    for iu in local.iam_users :
    "${iu.email} ${iu.is_account_sa}" => iu
  }
  project = var.project_id
  name = each.value.is_account_sa ? (
    trimsuffix(each.value.email, ".gserviceaccount.com")
    ) : (
    each.value.email
  )
  instance = google_sql_database_instance.default.name
  type     = each.value.is_account_sa ? "CLOUD_IAM_SERVICE_ACCOUNT" : "CLOUD_IAM_USER"

  depends_on = [
    null_resource.module_depends_on,
    google_project_iam_member.iam_binding,
  ]
}

resource "null_resource" "module_depends_on" {
  triggers = {
    value = length(var.module_depends_on)
  }
}

resource "google_sql_database_instance" "replicas" {
  for_each             = local.replicas
  project              = var.project_id
  name                 = "${local.master_instance_name}-replica${var.read_replica_name_suffix}${each.value.name}"
  database_version     = var.database_version
  region               = join("-", slice(split("-", lookup(each.value, "zone", var.zone)), 0, 2))
  master_instance_name = google_sql_database_instance.default.name
  deletion_protection  = var.read_replica_deletion_protection

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = lookup(each.value, "tier", var.tier)
    activation_policy = "ALWAYS"

    dynamic "ip_configuration" {
      for_each = [lookup(each.value, "ip_configuration", {})]
      content {
        ipv4_enabled    = lookup(ip_configuration.value, "ipv4_enabled", null)
        private_network = lookup(ip_configuration.value, "private_network", null)
        require_ssl     = lookup(ip_configuration.value, "require_ssl", null)

        dynamic "authorized_networks" {
          for_each = lookup(ip_configuration.value, "authorized_networks", [])
          content {
            expiration_time = lookup(authorized_networks.value, "expiration_time", null)
            name            = lookup(authorized_networks.value, "name", null)
            value           = lookup(authorized_networks.value, "value", null)
          }
        }
      }
    }
    dynamic "insights_config" {
      for_each = var.insights_config != null ? [var.insights_config] : []

      content {
        query_insights_enabled  = true
        query_string_length     = lookup(insights_config.value, "query_string_length", 1024)
        record_application_tags = lookup(insights_config.value, "record_application_tags", false)
        record_client_address   = lookup(insights_config.value, "record_client_address", false)
      }
    }

    disk_autoresize = lookup(each.value, "disk_autoresize", var.disk_autoresize)
    disk_size       = lookup(each.value, "disk_size", var.disk_size)
    disk_type       = lookup(each.value, "disk_type", var.disk_type)
    pricing_plan    = "PER_USE"
    user_labels     = lookup(each.value, "user_labels", var.user_labels)

    dynamic "database_flags" {
      for_each = lookup(each.value, "database_flags", [])
      content {
        name  = lookup(database_flags.value, "name", null)
        value = lookup(database_flags.value, "value", null)
      }
    }

    location_preference {
      zone = lookup(each.value, "zone", var.zone)
    }

  }

  depends_on = [google_sql_database_instance.default]

  lifecycle {
    ignore_changes = [
      settings[0].disk_size,
      settings[0].maintenance_window,
    ]
  }

  timeouts {
    create = var.create_timeout
    update = var.update_timeout
    delete = var.delete_timeout
  }
}

resource "google_sql_ssl_cert" "client_cert" {
  count       = var.enable_client_ssl ? 1 : 0
  common_name = var.client_cert_name
  instance    = google_sql_database_instance.default.name
}