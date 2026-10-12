# Security baseline for the namespace that hosts MCP servers. Every MCP server deployed there inherits it:
#   1. NetworkPolicy: default-deny ingress; only the gateway proxy pods may connect (any port).   [L3/L4, CNI]
#   2. PeerAuthentication STRICT: plaintext is refused by the sidecar.                           [mTLS]
#   3. AuthorizationPolicy: only the gateway's SPIFFE identity may call workloads in the namespace. [identity]
# Result: no path to an MCP server except through the gateway, so the gateway's decisions (token checks,
# rate limits, extAuth verdicts, client-address header) cannot be bypassed and its headers can be trusted.
# Each layer was verified on its own (docs in ecommerce-mcp-server: docs/SECURITY-POSTURE.md).
#
# A server that legitimately needs other callers (another MCP server, a metrics scraper) adds its own
# ALLOW AuthorizationPolicy + NetworkPolicy; Istio ALLOW policies are additive.

variable "namespace" {
  type    = string
  default = "mcp-servers"
}

variable "gateway_namespace" {
  type    = string
  default = "agentgateway-system"
}

variable "gateway_name" {
  description = "Gateway whose proxy pods (label gateway.networking.k8s.io/gateway-name) may call MCP servers."
  type        = string
  default     = "agentgateway-proxy"
}

variable "gateway_service_account" {
  type    = string
  default = "agentgateway-proxy"
}

variable "mesh_trust_domain" {
  description = "Trust domain the Istio CA actually issues (meshConfig.trustDomain)."
  type        = string
}

locals {
  docs = [
    {
      apiVersion = "networking.k8s.io/v1"
      kind       = "NetworkPolicy"
      metadata   = { name = "default-deny-ingress", namespace = var.namespace }
      spec       = { podSelector = {}, policyTypes = ["Ingress"] }
    },
    {
      apiVersion = "networking.k8s.io/v1"
      kind       = "NetworkPolicy"
      metadata   = { name = "allow-from-gateway", namespace = var.namespace }
      spec = {
        podSelector = {}
        policyTypes = ["Ingress"]
        ingress = [{
          from = [{
            namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.gateway_namespace } }
            podSelector       = { matchLabels = { "gateway.networking.k8s.io/gateway-name" = var.gateway_name } }
          }]
        }]
      }
    },
    {
      apiVersion = "security.istio.io/v1"
      kind       = "PeerAuthentication"
      metadata   = { name = "strict", namespace = var.namespace }
      spec       = { mtls = { mode = "STRICT" } }
    },
    {
      apiVersion = "security.istio.io/v1"
      kind       = "AuthorizationPolicy"
      metadata   = { name = "allow-gateway-only", namespace = var.namespace }
      spec = {
        action = "ALLOW"
        rules = [{
          from = [{ source = { principals = ["${var.mesh_trust_domain}/ns/${var.gateway_namespace}/sa/${var.gateway_service_account}"] } }]
        }]
      }
    },
  ]
  manifest = join("\n---\n", [for d in local.docs : yamlencode(d)])
}

resource "local_file" "baseline" {
  filename = "${path.module}/.generated/${var.namespace}-baseline.yaml"
  content  = local.manifest
}

resource "null_resource" "baseline" {
  triggers = {
    content_hash = sha256(local.manifest)
    file         = local_file.baseline.filename
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${self.triggers.file}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f ${self.triggers.file} --ignore-not-found=true"
  }
}
