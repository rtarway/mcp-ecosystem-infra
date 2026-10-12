resource_profile          = "laptop-16gb"
spire_trust_domain        = "mcp.lab.internal"
istio_version             = "1.30.5"
spire_chart_version       = "0.30.3"
spire_crds_chart_version  = "0.6.1"
agentgateway_version      = "1.6.0"
keycloak_operator_version = "26.8.0"

# keycloak_admin_password left unset -> Terraform generates and stores a random one;
# read it back with: terraform output -raw keycloak_admin_password

# MCP server teams onboarded onto this platform (name => their tenant.yaml, relative to terraform/).
tenants = {
  ecommerce = "../../ecommerce-mcp-server/platform/tenant.yaml"
}
