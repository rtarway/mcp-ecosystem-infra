module "namespaces" {
  source = "./modules/namespaces"
}

module "spire" {
  source             = "./modules/spire"
  trust_domain       = var.spire_trust_domain
  chart_version      = var.spire_chart_version
  crds_chart_version = var.spire_crds_chart_version

  depends_on = [module.namespaces]
}

module "istio" {
  source        = "./modules/istio"
  chart_version = var.istio_version
  trust_domain  = var.mesh_trust_domain # one cluster = one trust domain for every MCP server

  depends_on = [module.namespaces, module.spire]
}

module "keycloak" {
  source           = "./modules/keycloak"
  operator_version = var.keycloak_operator_version
  admin_password   = var.keycloak_admin_password
  public_url       = var.keycloak_public_url

  depends_on = [module.namespaces]
}

module "agentgateway" {
  source            = "./modules/agentgateway"
  chart_version     = var.agentgateway_version
  mesh_trust_domain = var.mesh_trust_domain

  depends_on = [module.namespaces, module.istio]
}

# Namespace security for MCP servers: default-deny, STRICT mTLS, only the gateway's identity may call.
module "mcp_servers_baseline" {
  source            = "./modules/mcp-servers-baseline"
  namespace         = var.shared_mcp_namespace
  mesh_trust_domain = var.mesh_trust_domain

  depends_on = [module.namespaces, module.istio, module.agentgateway]
}

# ---------------------------------------------------------------------------------------------------------------
# Tenants: MCP server teams. Each team keeps a tenant.yaml in its own repo (namespace, gateway paths, identity
# needs); registering it here is the whole onboarding. See docs/onboarding.md.
locals {
  tenant_specs = { for name, path in var.tenants : name => yamldecode(file(path)) }

  _paths   = flatten([for n, t in local.tenant_specs : [for p in try(t.gateway.paths, []) : { tenant = n, path = p }]])
  _clients = flatten([for n, t in local.tenant_specs : [for c in try(t.idp.clients, []) : { tenant = n, id = c.clientId }]])
  _scopes = flatten([for n, t in local.tenant_specs : [
    for s in concat(try(t.idp.resourceScopes, []), try(t.idp.consentScopes, [])) : { tenant = n, id = s.name }
  ]])
  _dedicated = [for n, t in local.tenant_specs : { tenant = n, ns = t.namespace } if t.namespace != var.shared_mcp_namespace]

  path_conflicts = distinct(flatten([for a in local._paths : [
    for b in local._paths : join(" vs ", sort(["${a.path} (${a.tenant})", "${b.path} (${b.tenant})"]))
    if a.tenant != b.tenant && (startswith(a.path, b.path) || startswith(b.path, a.path))
  ]]))
  client_conflicts = distinct([for a in local._clients : a.id if length([for b in local._clients : b if b.id == a.id && b.tenant != a.tenant]) > 0])
  scope_conflicts  = distinct([for a in local._scopes : a.id if length([for b in local._scopes : b if b.id == a.id && b.tenant != a.tenant]) > 0])
  ns_conflicts     = distinct([for a in local._dedicated : a.ns if length([for b in local._dedicated : b if b.ns == a.ns && b.tenant != a.tenant]) > 0])
}

resource "terraform_data" "tenant_registry_checks" {
  input = keys(local.tenant_specs)
  lifecycle {
    precondition {
      condition     = alltrue([for n, t in local.tenant_specs : try(t.kind, "") == "McpTenant" && try(t.name, "") == n && can(t.namespace)])
      error_message = "Each tenant file needs kind: McpTenant, name equal to its key in var.tenants, and a namespace."
    }
    precondition {
      condition     = length(local.path_conflicts) == 0
      error_message = "Tenants claim overlapping gateway paths: ${join("; ", local.path_conflicts)}"
    }
    precondition {
      condition     = length(local.client_conflicts) == 0 && length(local.scope_conflicts) == 0
      error_message = "Identity-provider names are shared by several tenants: clients ${jsonencode(local.client_conflicts)}, scopes ${jsonencode(local.scope_conflicts)}"
    }
    precondition {
      condition     = length(local.ns_conflicts) == 0
      error_message = "Dedicated namespaces requested by more than one tenant: ${jsonencode(local.ns_conflicts)} (use the shared namespace instead)"
    }
  }
}

module "tenant" {
  for_each = local.tenant_specs
  source   = "./modules/mcp-tenant"

  name                    = each.key
  spec                    = each.value
  shared_namespace        = var.shared_mcp_namespace
  mesh_trust_domain       = var.mesh_trust_domain
  keycloak_admin_password = module.keycloak.admin_password
  allowed_admin_roles     = var.tenant_allowed_admin_roles

  depends_on = [terraform_data.tenant_registry_checks, module.keycloak, module.mcp_servers_baseline, module.agentgateway]
}

output "tenants" {
  value = { for n, m in module.tenant : n => m.namespace }
}

output "keycloak_issuer" {
  value = module.keycloak.issuer
}

output "test_user_password" {
  value     = module.keycloak.test_user_password
  sensitive = true
}

output "keycloak_admin_password" {
  value     = module.keycloak.admin_password
  sensitive = true
}

output "next_steps" {
  value = <<-EOT
    Infra applied. Verify with:
      kubectl get pods -A
      kubectl get gatewayclass   # expect "agentgateway"
      kubectl get keycloak -n keycloak

    Retrieve the Keycloak admin password:
      terraform output -raw keycloak_admin_password

    Port-forward Keycloak to reach the admin console:
      kubectl port-forward -n keycloak svc/keycloak-service 8080:8080

    See docs/phase-plan.md for what's next (SPIRE<->Istio CA federation, Keycloak
    realm/client/OAuth2.1 config, agentgateway MCP routing + auth policy, MCP servers).
  EOT
}
