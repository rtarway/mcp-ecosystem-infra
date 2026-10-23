variable "namespace" {
  description = "Namespace of keycloak-service (the route lives next to it, so no ReferenceGrant is needed)."
  type        = string
  default     = "keycloak"
}

variable "realm_name" {
  type = string
}

variable "gateway_name" {
  type    = string
  default = "agentgateway-proxy"
}

variable "gateway_namespace" {
  type    = string
  default = "agentgateway-system"
}

variable "hostnames" {
  description = "Host names the sign-in endpoints answer on; must match the MCP routes so they share one origin."
  type        = list(string)
  default     = ["localhost", "127.0.0.1"]
}

# Sign-in on the shared gateway. Clients discover the authorization server from an MCP server's protected-resource
# metadata and then call it for metadata, registration (DCR), authorization, token and revocation. Serving it on the
# same origin as the MCP servers:
#   - works with clients that refuse OAuth fetches to other private-network origins (OpenClaw's SSRF guard);
#   - gives one front door for TLS, rate limits and client-address handling, as in production.
# Only this realm is published: no master realm, no admin console or admin REST API (/admin), no health/metrics.
locals {
  realm = "/realms/${var.realm_name}"

  route_yaml = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "keycloak-${var.realm_name}", namespace = var.namespace }
    spec = {
      parentRefs = [{ name = var.gateway_name, namespace = var.gateway_namespace }]
      hostnames  = var.hostnames
      rules = [{
        matches = [
          { path = { type = "PathPrefix", value = local.realm } },
          # RFC 8414 metadata at the path-inserted location MCP clients try first.
          { path = { type = "Exact", value = "/.well-known/oauth-authorization-server${local.realm}" } },
          # Stylesheets and scripts of the login and consent pages.
          { path = { type = "PathPrefix", value = "/resources/" } },
        ]
        backendRefs = [{ name = "keycloak-service", port = 8080 }]
      }]
    }
  })

  policy_yaml = yamlencode({
    apiVersion = "agentgateway.dev/v1alpha1"
    kind       = "AgentgatewayPolicy"
    metadata   = { name = "keycloak-${var.realm_name}-edge", namespace = var.namespace }
    spec = {
      targetRefs = [{ group = "gateway.networking.k8s.io", kind = "HTTPRoute", name = "keycloak-${var.realm_name}" }]
      traffic = {
        # Per client address; Keycloak's brute-force protection handles password guessing per account.
        rateLimit = { local = [{ requests = 600, unit = "Minutes", burst = 100, key = "source.address" }] }
        transformation = {
          request = {
            # Keycloak trusts X-Forwarded-* from the gateway (modules/keycloak proxy settings), so the gateway
            # decides them: the client's own values are dropped and the observed address is stamped.
            remove = ["forwarded", "x-forwarded-host", "x-forwarded-proto", "x-forwarded-port", "x-forwarded-prefix"]
            set    = [{ name = "x-forwarded-for", value = "source.address" }]
          }
        }
      }
    }
  })
}

resource "local_file" "route" {
  filename = "${path.module}/.generated/auth-route-${var.realm_name}.yaml"
  content  = "${local.route_yaml}\n---\n${local.policy_yaml}"
}

resource "null_resource" "route" {
  triggers = {
    content_hash = sha256(local_file.route.content)
    file         = local_file.route.filename
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${self.triggers.file}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f ${self.triggers.file} --ignore-not-found=true"
  }
}
