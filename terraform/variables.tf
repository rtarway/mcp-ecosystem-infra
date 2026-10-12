variable "resource_profile" {
  description = "Sizing profile for chart values (affects replica counts / requests)."
  type        = string
  default     = "laptop-16gb" # matches the 16GB/6-8vCPU envelope you specified

  validation {
    condition     = contains(["laptop-8gb", "laptop-16gb", "laptop-32gb"], var.resource_profile)
    error_message = "resource_profile must be one of: laptop-8gb, laptop-16gb, laptop-32gb."
  }
}

variable "spire_trust_domain" {
  description = "SPIFFE trust domain for the mesh, e.g. mcp.lab.internal"
  type        = string
  default     = "mcp.lab.internal"
}

variable "mesh_trust_domain" {
  description = <<-EOT
    SPIFFE trust domain of the mesh: identities are spiffe://<this>/ns/<namespace>/sa/<service account>.
    Single local cluster, so every MCP server shares one trust domain; `cluster.local` is Istio's default and what
    istiod issues. Used for the gateway's identity and every AuthorizationPolicy principal.
  EOT
  type        = string
  default     = "cluster.local"
}

variable "istio_version" {
  description = "Istio chart/app version"
  type        = string
  default     = "1.30.5" # newest stable on the official Helm repo (1.31 GA not yet published as charts)
}

variable "spire_chart_version" {
  description = "spire (spiffe/helm-charts-hardened) chart version"
  type        = string
  default     = "0.30.3"
}

variable "spire_crds_chart_version" {
  description = "spire-crds chart version (versioned independently of the spire chart)"
  type        = string
  default     = "0.6.1"
}

variable "agentgateway_version" {
  description = "agentgateway OCI chart version (agentgateway + agentgateway-crds)"
  type        = string
  default     = "1.6.0"
}

variable "keycloak_operator_version" {
  description = "Keycloak Operator version (matches Keycloak server version it manages)"
  type        = string
  default     = "26.8.0"
}

variable "keycloak_admin_password" {
  description = "Initial Keycloak admin password (dev only — rotate before anything real touches this)."
  type        = string
  sensitive   = true
  default     = null # if null, a random password is generated (see modules/keycloak)
}

variable "keycloak_public_url" {
  description = "Keycloak URL as seen by clients (port-forward); determines the token issuer."
  type        = string
  default     = "http://localhost:8080"
}

variable "tenants" {
  description = <<-EOT
    MCP server teams onboarded onto the platform: name => path to that team's tenant.yaml (in its own repo).
    Paths are relative to the directory terraform runs in (this one). See docs/onboarding.md.
  EOT
  type        = map(string)
  default     = {}
}

variable "shared_mcp_namespace" {
  description = "Namespace any tenant may deploy into without its own; secured by modules/mcp-servers-baseline."
  type        = string
  default     = "mcp-servers"
}

variable "tenant_allowed_admin_roles" {
  description = <<-EOT
    realm-management roles a tenant's service account may request. manage-users is realm-wide (it can end any user's
    sessions); it is allowed because a session-manager's theft response needs it. Tighten per tenant in production.
  EOT
  type        = list(string)
  default     = ["view-users", "query-users", "view-events", "manage-users"]
}
