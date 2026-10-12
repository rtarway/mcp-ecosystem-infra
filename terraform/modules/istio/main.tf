variable "namespace" {
  type    = string
  default = "istio-system"
}

variable "chart_version" {
  type = string
}

variable "trust_domain" {
  description = "Must match the SPIRE trust domain for Phase 2b federation."
  type        = string
}

# Official Istio charts: https://istio-release.storage.googleapis.com/charts
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false
  wait             = true

  set {
    name  = "global.istioNamespace"
    value = var.namespace
  }
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.chart_version
  namespace  = var.namespace
  wait       = true
  timeout    = 300

  values = [yamlencode({
    global = {
      # NOTE (Phase 2b): trustDomain is set now so it's consistent from day one, but
      # istiod is still acting as its own CA (Citadel) at this point — it is NOT yet
      # delegating certificate issuance to SPIRE. Full SPIRE-as-CA requires configuring
      # istio-agent to fetch certs from SPIRE's SDS/Workload API socket instead of
      # istiod, via a CSI driver mount + CA_PROVIDER=... this is deliberately left for
      # a follow-up apply once base mesh connectivity is verified. See docs/phase-plan.md.
      trustDomain = var.trust_domain
    }
    pilot = {
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }
  })]

  depends_on = [helm_release.istio_base]
}
