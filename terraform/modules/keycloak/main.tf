variable "namespace" {
  type    = string
  default = "keycloak"
}

variable "operator_version" {
  description = "Also the Keycloak server version this operator release manages."
  type        = string
}

variable "public_url" {
  description = "Externally visible Keycloak base URL (the shared gateway); becomes the issuer host in tokens."
  type        = string
  default     = "http://localhost:8000"
}

variable "admin_url" {
  description = "Admin console URL. Not published on the gateway; reached with a port-forward only."
  type        = string
  default     = "http://localhost:8080"
}

variable "trusted_proxy_cidrs" {
  description = "Addresses whose X-Forwarded-* headers Keycloak believes (the gateway pods). Pod CIDR of the local cluster."
  type        = list(string)
  default     = ["10.42.0.0/16"]
}

variable "realm_name" {
  type    = string
  default = "mcp"
}

variable "admin_password" {
  type      = string
  sensitive = true
  default   = null
}

# The Keycloak project does not publish an official Helm chart for the server — they
# recommend the Operator, shipped as a static multi-document manifest per release.
# We apply it with kubectl rather than shoehorning it into helm_release.
# Official source: https://github.com/keycloak/keycloak-k8s-resources

resource "random_password" "admin" {
  count   = var.admin_password == null ? 1 : 0
  length  = 24
  special = true
}

locals {
  admin_password = coalesce(var.admin_password, try(random_password.admin[0].result, null))
  k8s_resources  = "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${var.operator_version}/kubernetes"
  operator_crds = [
    "keycloaks.k8s.keycloak.org-v1.yml",
    "keycloakrealmimports.k8s.keycloak.org-v1.yml",
    "keycloakoidcclients.k8s.keycloak.org-v1.yml",
    "keycloaksamlclients.k8s.keycloak.org-v1.yml",
  ]
}

# CRDs are published as separate files from the operator deployment manifest.
resource "null_resource" "keycloak_operator_crds" {
  triggers = {
    version = var.operator_version
    crds    = join(" ", [for f in local.operator_crds : "${local.k8s_resources}/${f}"])
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${replace(self.triggers.crds, " ", " -f ")}"
  }
}

resource "null_resource" "keycloak_operator" {
  triggers = {
    version   = var.operator_version
    namespace = var.namespace
    url       = "${local.k8s_resources}/kubernetes.yml"
  }

  provisioner "local-exec" {
    command = "kubectl apply -n ${self.triggers.namespace} -f ${self.triggers.url}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -n ${self.triggers.namespace} -f ${self.triggers.url} --ignore-not-found=true"
  }

  depends_on = [null_resource.keycloak_operator_crds]
}

# --- Minimal Postgres backing store (lab-grade: single replica, emptyDir-backed PVC via
#     default StorageClass, no HA). Swap for a managed/HA Postgres before this is anything
#     but a laptop lab. ---

resource "kubernetes_secret" "postgres_credentials" {
  metadata {
    name      = "keycloak-postgres-credentials"
    namespace = var.namespace
  }
  data = {
    POSTGRES_DB       = "keycloak"
    POSTGRES_USER     = "keycloak"
    POSTGRES_PASSWORD = random_password.postgres[0].result
  }
}

resource "random_password" "postgres" {
  count   = 1
  length  = 24
  special = false
}

resource "kubernetes_stateful_set" "postgres" {
  metadata {
    name      = "keycloak-postgres"
    namespace = var.namespace
  }
  spec {
    service_name = "keycloak-postgres"
    replicas     = 1
    selector {
      match_labels = { app = "keycloak-postgres" }
    }
    template {
      metadata {
        labels = { app = "keycloak-postgres" }
      }
      spec {
        container {
          name  = "postgres"
          image = "postgres:16-alpine"
          env_from {
            secret_ref {
              name = kubernetes_secret.postgres_credentials.metadata[0].name
            }
          }
          port {
            container_port = 5432
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = { storage = "2Gi" }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
  metadata {
    name      = "keycloak-postgres"
    namespace = var.namespace
  }
  spec {
    selector = { app = "keycloak-postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
    cluster_ip = "None"
  }
}

resource "kubernetes_secret" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin-credentials"
    namespace = var.namespace
  }
  data = {
    username = "admin"
    password = local.admin_password
  }
}

# The Keycloak CR itself — rendered to a file and applied with the same `kubectl`
# binary Rancher Desktop ships (no third-party Terraform provider needed for this).
locals {
  keycloak_cr_yaml = yamlencode({
    apiVersion = "k8s.keycloak.org/v2beta1"
    kind       = "Keycloak"
    metadata = {
      name      = "keycloak"
      namespace = var.namespace
    }
    spec = {
      instances = 1
      db = {
        vendor = "postgres"
        host   = kubernetes_service.postgres.metadata[0].name
        usernameSecret = {
          name = kubernetes_secret.postgres_credentials.metadata[0].name
          key  = "POSTGRES_USER"
        }
        passwordSecret = {
          name = kubernetes_secret.postgres_credentials.metadata[0].name
          key  = "POSTGRES_PASSWORD"
        }
      }
      # Lab-only: HTTP enabled + TLS off so you can stand this up without a cert chain
      # first. Before any external client hits this for real, put TLS in front (kgateway
      # or a cert-manager-issued cert on the Keycloak CR's `http.tlsSecret`) — OAuth 2.1
      # requires TLS on every endpoint except localhost redirect URIs.
      http = {
        httpEnabled = true
      }
      # Fixed public URL so the token `iss` claim is stable: clients reach login, registration and token endpoints
      # through the shared gateway (modules/auth-route), on the same origin as the MCP servers. Some clients only
      # allow private-network OAuth fetches to the MCP server's own origin (OpenClaw), and one front door is the
      # production shape anyway. The admin console has its own URL and is not routed by the gateway.
      # In-cluster callers (JWKS, token exchange, admin API) use keycloak-service directly; `iss` stays the public URL.
      hostname = {
        hostname = var.public_url
        admin    = var.admin_url
        strict   = false
      }
      # Client address for brute-force protection, events and DCR trusted-hosts checks comes from the gateway's
      # X-Forwarded-For (the gateway overwrites whatever the client sent); believed only from pod addresses.
      proxy = {
        headers = "xforwarded"
      }
      additionalOptions = [
        { name = "proxy-trusted-addresses", value = join(",", var.trusted_proxy_cidrs) },
      ]
      bootstrapAdmin = {
        user = {
          secret = kubernetes_secret.keycloak_admin.metadata[0].name
        }
      }
    }
  })
}

resource "local_file" "keycloak_cr" {
  filename = "${path.module}/.generated/keycloak-cr.yaml"
  content  = local.keycloak_cr_yaml
}

# Re-applies whenever the rendered CR content changes. No destroy step here: a content change replaces this
# resource, and deleting the CR on every change would take Keycloak down. Deletion lives in keycloak_cr_lifecycle.
resource "null_resource" "apply_keycloak_cr" {
  triggers = {
    content_hash = sha256(local.keycloak_cr_yaml)
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${local_file.keycloak_cr.filename}"
  }

  depends_on = [
    local_file.keycloak_cr,
    null_resource.keycloak_operator,
    kubernetes_stateful_set.postgres,
  ]
}

# Deletes the Keycloak CR only on a real destroy (triggers never change).
resource "null_resource" "keycloak_cr_lifecycle" {
  triggers = {
    name      = "keycloak"
    namespace = var.namespace
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete keycloak/${self.triggers.name} -n ${self.triggers.namespace} --ignore-not-found=true"
  }

  depends_on = [null_resource.apply_keycloak_cr]
}

# --- Realm for the MCP ecosystem (imported once by the operator) ---
# NOTE: no `clientScopes` here on purpose. Declaring any makes Keycloak skip its built-in default
# scopes (basic -> `sub`, profile, email, roles ...), which breaks every token. App-specific scopes
# (audience, consent scopes) are added per application via the Admin API.
# DCR (RFC 7591) is on by default in Keycloak's `anonymous` client-registration policies;
# clients below use Authorization Code + PKCE (S256) and the device grant. Password grant is OFF.
resource "random_password" "test_user" {
  length  = 20
  special = false
}

locals {
  realm_import_yaml = yamlencode({
    apiVersion = "k8s.keycloak.org/v2beta1"
    kind       = "KeycloakRealmImport"
    metadata = {
      name      = "${var.realm_name}-realm"
      namespace = var.namespace
    }
    spec = {
      keycloakCRName = "keycloak"
      realm = {
        realm                = var.realm_name
        enabled              = true
        sslRequired          = "external"
        accessTokenLifespan  = 300
        revokeRefreshToken   = true
        refreshTokenMaxReuse = 0
        registrationAllowed  = false
        groups               = [{ name = "users" }]
        users = [{
          username      = "testuser"
          enabled       = true
          email         = "testuser@mcp.lab.internal"
          emailVerified = true
          firstName     = "Test"
          lastName      = "User"
          groups        = ["/users"]
          # Imported users do NOT get the realm default roles automatically; without this,
          # offline_access (refresh tokens for clients such as MCP Inspector) is refused.
          realmRoles  = ["default-roles-${var.realm_name}"]
          credentials = [{ type = "password", value = random_password.test_user.result, temporary = false }]
        }]
        clients = [{
          clientId                  = "mcp-test-client"
          name                      = "MCP test client (public, PKCE)"
          enabled                   = true
          publicClient              = true
          standardFlowEnabled       = true
          directAccessGrantsEnabled = false
          implicitFlowEnabled       = false
          redirectUris              = ["http://localhost:*", "http://127.0.0.1:*"]
          webOrigins                = ["+"]
          attributes = {
            "pkce.code.challenge.method"                = "S256"
            "oauth2.device.authorization.grant.enabled" = "true"
          }
        }]
      }
    }
  })
}

resource "local_file" "realm_import" {
  filename        = "${path.module}/.generated/realm-${var.realm_name}.yaml"
  content         = local.realm_import_yaml
  file_permission = "0600"
}

resource "null_resource" "apply_realm" {
  triggers = {
    content_hash = sha256(local.realm_import_yaml)
    file         = local_file.realm_import.filename
  }

  provisioner "local-exec" {
    command = "kubectl wait --for=condition=Ready keycloak/keycloak -n ${var.namespace} --timeout=300s && kubectl apply -f ${self.triggers.file}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f ${self.triggers.file} --ignore-not-found=true"
  }

  depends_on = [null_resource.apply_keycloak_cr]
}

output "test_user_password" {
  value     = random_password.test_user.result
  sensitive = true
}

output "issuer" {
  value = "${var.public_url}/realms/${var.realm_name}"
}

output "admin_password" {
  value     = local.admin_password
  sensitive = true
}

# --- Realm security baseline (scripts/realm-baseline.sh) ---
# The realm import above only runs when the realm is first created, so settings that must also reach an
# existing realm are applied through the Admin API. Re-runs whenever the script changes. Opens its own
# temporary port-forward (port 18080) so it does not depend on the developer's :8080 forward.
resource "null_resource" "realm_baseline" {
  triggers = {
    script_hash = filesha256("${path.module}/scripts/realm-baseline.sh")
    realm       = var.realm_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubectl -n ${var.namespace} port-forward svc/keycloak-service 18080:8080 >/dev/null 2>&1 &
      PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
      for i in $(seq 1 60); do curl -sf -o /dev/null http://localhost:18080/realms/${var.realm_name} && break; sleep 2; done
      KC_URL=http://localhost:18080 REALM=${var.realm_name} ${path.module}/scripts/realm-baseline.sh
    EOT
    environment = {
      KC_ADMIN_PASSWORD = local.admin_password
    }
  }

  depends_on = [null_resource.apply_realm]
}
