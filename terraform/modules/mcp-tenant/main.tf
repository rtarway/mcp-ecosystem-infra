# Onboards one MCP server team ("tenant") onto the platform from the tenant.yaml in the team's own repo.
#   - namespace: the shared one (already secured by the platform), or a dedicated one that this module creates with
#     mesh injection and the same security baseline (default-deny, STRICT mTLS, only the gateway may call);
#   - identity provider: the tenant's scopes, clients, service-account roles and secrets, applied with the platform's
#     admin credentials (scripts/onboard_idp.py), so the team never holds them.
# Gateway resources (HTTPRoute, AgentgatewayBackend, AgentgatewayPolicy) stay in the team's repo; the root module only
# checks that no two tenants claim the same paths.

variable "name" {
  type = string
}

variable "spec" {
  description = "Decoded tenant.yaml."
  type        = any
}

variable "shared_namespace" {
  type = string
}

variable "mesh_trust_domain" {
  type = string
}

variable "keycloak_namespace" {
  type    = string
  default = "keycloak"
}

variable "realm" {
  type    = string
  default = "mcp"
}

variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}

variable "allowed_admin_roles" {
  description = "realm-management roles a tenant's service account may be given."
  type        = list(string)
}

locals {
  namespace = var.spec.namespace
  dedicated = local.namespace != var.shared_namespace
  idp_json  = jsonencode(try(var.spec.idp, {}))
}

resource "kubernetes_namespace" "dedicated" {
  count = local.dedicated ? 1 : 0

  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "mcp.platform/tenant"          = var.name
      "istio-injection"              = "enabled"
      # istio-init needs NET_ADMIN until Istio CNI is installed (same as the shared namespace).
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

module "baseline" {
  count             = local.dedicated ? 1 : 0
  source            = "../mcp-servers-baseline"
  namespace         = local.namespace
  mesh_trust_domain = var.mesh_trust_domain

  depends_on = [kubernetes_namespace.dedicated]
}

resource "null_resource" "idp" {
  triggers = {
    spec_hash   = sha256(local.idp_json)
    script_hash = filesha256("${path.module}/scripts/onboard_idp.py")
    namespace   = local.namespace
    roles       = join(",", var.allowed_admin_roles)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # Own port-forward on a free port (tenants are onboarded in parallel; no dependency on a developer's :8080).
    command = <<-EOT
      set -euo pipefail
      LOG=$(mktemp)
      kubectl -n ${var.keycloak_namespace} port-forward svc/keycloak-service :8080 >"$LOG" 2>&1 &
      PF=$!; trap 'kill $PF 2>/dev/null || true; rm -f "$LOG"' EXIT
      for i in $(seq 1 30); do PORT=$(sed -n 's/.*127.0.0.1:\([0-9]*\) ->.*/\1/p' "$LOG" | head -1); [ -n "$PORT" ] && break; sleep 1; done
      for i in $(seq 1 30); do curl -sf -o /dev/null "http://localhost:$PORT/realms/${var.realm}" && break; sleep 1; done
      KC_URL="http://localhost:$PORT" python3 ${path.module}/scripts/onboard_idp.py
    EOT
    environment = {
      KC_ADMIN_PASSWORD   = var.keycloak_admin_password
      REALM               = var.realm
      TENANT              = var.name
      TENANT_NAMESPACE    = local.namespace
      TENANT_SPEC         = local.idp_json
      ALLOWED_ADMIN_ROLES = join(",", var.allowed_admin_roles)
    }
  }

  depends_on = [kubernetes_namespace.dedicated]
}

output "namespace" {
  value = local.namespace
}
