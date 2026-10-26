variable "namespace" {
  description = "Where the job runs: next to Keycloak (platform namespace, not a tenant's)."
  type        = string
  default     = "keycloak"
}

variable "realm" {
  type    = string
  default = "mcp"
}

variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}

variable "max_age_days" {
  description = "Self-registered clients and consents older than this are removed; the customer's agent then starts over."
  type        = number
  default     = 30
}

variable "schedule" {
  type    = string
  default = "17 3 * * *" # daily, at a quiet hour
}

variable "dry_run" {
  description = "Log what would be removed without removing it."
  type        = bool
  default     = false
}

variable "image" {
  type    = string
  default = "python:3.13-alpine"
}

# One 30-day clock for every linked MCP client (ecommerce-mcp-server docs/CLIENT-COMPATIBILITY-REPORT.md R6):
# Keycloak has no expiry for clients or consents. Offline sessions already end at 30 days (realm baseline); this job
# removes self-registered clients and revokes consents on the same clock. Platform-owned because both are realm-wide.
locals {
  client_id   = "platform-client-expiry"
  secret_name = "client-expiry-credentials"
}

resource "null_resource" "job_client" {
  triggers = {
    script_hash = filesha256("${path.module}/scripts/ensure_job_client.py")
    namespace   = var.namespace
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      LOG=$(mktemp)
      kubectl -n ${var.namespace} port-forward svc/keycloak-service :8080 >"$LOG" 2>&1 &
      PF=$!; trap 'kill $PF 2>/dev/null || true; rm -f "$LOG"' EXIT
      for i in $(seq 1 30); do PORT=$(sed -n 's/.*127.0.0.1:\([0-9]*\) ->.*/\1/p' "$LOG" | head -1); [ -n "$PORT" ] && break; sleep 1; done
      for i in $(seq 1 30); do curl -sf -o /dev/null "http://localhost:$PORT/realms/${var.realm}" && break; sleep 1; done
      KC_URL="http://localhost:$PORT" python3 ${path.module}/scripts/ensure_job_client.py
    EOT
    environment = {
      KC_ADMIN_PASSWORD = var.keycloak_admin_password
      REALM             = var.realm
      CLIENT_ID         = local.client_id
      NAMESPACE         = var.namespace
      SECRET_NAME       = local.secret_name
    }
  }
}

resource "kubernetes_config_map" "script" {
  metadata {
    name      = "client-expiry-script"
    namespace = var.namespace
  }
  data = {
    "expire.py" = file("${path.module}/scripts/expire.py")
  }
}

resource "kubernetes_cron_job_v1" "expiry" {
  metadata {
    name      = "client-expiry"
    namespace = var.namespace
    labels    = { app = "client-expiry" }
  }
  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = { app = "client-expiry" }
      }
      spec {
        backoff_limit = 1
        template {
          metadata {
            labels = { app = "client-expiry" }
          }
          spec {
            restart_policy = "Never"
            security_context {
              run_as_non_root = true
              run_as_user     = 65534
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }
            container {
              name    = "expire"
              image   = var.image
              command = ["python3", "/job/expire.py"]
              env {
                name  = "KC_URL"
                value = "http://keycloak-service.${var.namespace}.svc.cluster.local:8080"
              }
              env {
                name  = "REALM"
                value = var.realm
              }
              env {
                name  = "MAX_AGE_SECONDS"
                value = tostring(var.max_age_days * 86400)
              }
              env {
                name  = "DRY_RUN"
                value = tostring(var.dry_run)
              }
              env_from {
                secret_ref {
                  name = local.secret_name
                }
              }
              volume_mount {
                name       = "script"
                mount_path = "/job"
                read_only  = true
              }
              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                capabilities {
                  drop = ["ALL"]
                }
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { cpu = "200m", memory = "128Mi" }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.script.metadata[0].name
              }
            }
          }
        }
      }
    }
  }

  depends_on = [null_resource.job_client]
}

output "cronjob" {
  value = "${var.namespace}/${kubernetes_cron_job_v1.expiry.metadata[0].name}"
}
