variable "namespace" {
  type    = string
  default = "agentgateway-system"
}

variable "chart_version" {
  type = string
}

variable "mesh_trust_domain" {
  description = "Trust domain the Istio CA actually issues (meshConfig.trustDomain), used for the gateway's SPIFFE identity."
  type        = string
}

# agentgateway (Linux Foundation project, https://agentgateway.dev): Gateway API data plane
# with native MCP / A2A / LLM routing. Official OCI charts at cr.agentgateway.dev.
#
# Prerequisite: Gateway API CRDs >= v1.5.0 (standard channel). Rancher Desktop's k3s
# installs them via its bundled Traefik CRD chart (v1.5.1), so nothing to apply here.
# If you ever disable Traefik entirely, apply them yourself:
#   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml

resource "helm_release" "agentgateway_crds" {
  name       = "agentgateway-crds"
  repository = "oci://cr.agentgateway.dev/charts"
  chart      = "agentgateway-crds"
  version    = var.chart_version
  namespace  = var.namespace
  wait       = true
}

resource "helm_release" "agentgateway" {
  name       = "agentgateway"
  repository = "oci://cr.agentgateway.dev/charts"
  chart      = "agentgateway"
  version    = var.chart_version
  namespace  = var.namespace
  wait       = true
  timeout    = 300

  depends_on = [helm_release.agentgateway_crds]
}

# Shared HTTP entry point. Per-MCP-server HTTPRoutes + JWT policies attach to it
# (see docs/mcp-route-template.yaml). TLS listener comes with the TLS work in Phase 3.
#
# Mesh identity: with `istio.enabled` the proxy gets its own SPIFFE certificate from istiod
# (spiffe://<trust domain>/ns/agentgateway-system/sa/agentgateway-proxy) without a sidecar, and talks
# mTLS natively to mesh workloads. This is what lets MCP servers run STRICT mTLS and authorise the
# gateway by identity (modules/mcp-servers-baseline). Backends must be selected by label
# (AgentgatewayBackend `selector`) or plain Service backendRefs; a `static` host is sent in plaintext.
locals {
  params_yaml = yamlencode({
    apiVersion = "agentgateway.dev/v1alpha1"
    kind       = "AgentgatewayParameters"
    metadata   = { name = "mesh-identity", namespace = var.namespace }
    spec = {
      istio = { enabled = true, trustDomain = var.mesh_trust_domain }
    }
  })

  gateway_yaml = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata   = { name = "agentgateway-proxy", namespace = var.namespace }
    spec = {
      gatewayClassName = "agentgateway"
      infrastructure = {
        parametersRef = { group = "agentgateway.dev", kind = "AgentgatewayParameters", name = "mesh-identity" }
      }
      listeners = [{
        name          = "http"
        port          = 8000
        protocol      = "HTTP"
        allowedRoutes = { namespaces = { from = "All" } }
      }]
    }
  })
}

resource "local_file" "gateway" {
  filename = "${path.module}/.generated/gateway.yaml"
  content  = "${local.params_yaml}\n---\n${local.gateway_yaml}"
}

resource "null_resource" "gateway" {
  triggers = {
    content_hash = sha256(local_file.gateway.content)
    file         = local_file.gateway.filename
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${self.triggers.file}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f ${self.triggers.file} --ignore-not-found=true"
  }

  depends_on = [helm_release.agentgateway]
}
