variable "namespace" {
  type    = string
  default = "spire-system"
}

variable "trust_domain" {
  type = string
}

variable "chart_version" {
  type = string
}

variable "crds_chart_version" {
  type = string
}

# Official SPIFFE project charts: https://github.com/spiffe/helm-charts-hardened
resource "helm_release" "spire_crds" {
  name             = "spire-crds"
  repository       = "https://spiffe.github.io/helm-charts-hardened/"
  chart            = "spire-crds"
  version          = var.crds_chart_version
  namespace        = var.namespace
  create_namespace = false
  wait             = true
}

resource "helm_release" "spire" {
  name       = "spire"
  repository = "https://spiffe.github.io/helm-charts-hardened/"
  chart      = "spire"
  version    = var.chart_version
  namespace  = var.namespace
  wait       = true
  timeout    = 600

  values = [yamlencode({
    global = {
      spire = {
        trustDomain = var.trust_domain
        namespaces = {
          create = false # namespaces module already created spire-system
        }
      }
    }

    spire-server = {
      # NodeAttestor: k8s psat is the standard low-friction attestor for in-cluster agents
      # on any conformant cluster (works fine on Rancher Desktop's k3s).
      controllerManager = {
        enabled = true # spire-controller-manager: lets you manage SPIFFE IDs as k8s CRDs
        # (ClusterSPIFFEID) instead of hand-editing server config — this is what Phase 2b
        # (Istio <-> SPIRE cert delegation) and later MCP-server workload identity will use.
      }
      dataStore = {
        sql = {
          databaseType = "sqlite3" # fine for a lab; swap to postgres for anything durable
        }
      }
    }

    spire-agent = {
      # Runs as a DaemonSet, exposes the SPIFFE Workload API over a UDS that
      # istio-proxy sidecars will mount in Phase 2b.
      fullnameOverride = "spire-agent"
    }

    spiffe-oidc-discovery-provider = {
      enabled = false # not needed until you want SPIFFE-issued OIDC federation; off for now
    }
  })]

  depends_on = [helm_release.spire_crds]
}

output "trust_domain" {
  value = var.trust_domain
}
