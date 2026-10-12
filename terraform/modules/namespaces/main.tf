
locals {
  # psa = Pod Security Admission level enforced on the namespace.
  # - spire-system: SPIRE agent/CSI driver need hostPath + privileged.
  # - istio-system: istio-init/CNI-style components need elevated capabilities.
  # - mcp-servers: sidecar injection adds istio-init (NET_ADMIN), so it can't be
  #   baseline/restricted until Istio CNI is used; revisit in Phase 2b.
  # - keycloak: not injected yet (mesh onboarding is Phase 2b); postgres runs as root
  #   on startup, so baseline rather than restricted.
  namespaces = {
    "spire-system"        = { inject = false, psa = "privileged" }
    "istio-system"        = { inject = false, psa = "privileged" }
    "agentgateway-system" = { inject = false, psa = "baseline" }
    "keycloak"            = { inject = false, psa = "baseline" }
    "mcp-servers"         = { inject = true, psa = "privileged" }
  }
}

resource "kubernetes_namespace" "this" {
  for_each = local.namespaces

  metadata {
    name = each.key

    labels = merge(
      {
        "app.kubernetes.io/managed-by"       = "terraform"
        "pod-security.kubernetes.io/enforce" = each.value.psa
      },
      each.value.inject ? { "istio-injection" = "enabled" } : {}
    )
  }
}

output "namespace_names" {
  value = keys(local.namespaces)
}
