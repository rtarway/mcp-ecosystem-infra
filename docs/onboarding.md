# Onboarding an MCP server onto the platform

This platform (local proof of concept on Rancher Desktop) gives MCP server teams a Kubernetes cluster with a service
mesh, workload identity, an identity provider and an MCP-aware gateway, already secured. A team builds its MCP server
and **describes** what it needs from the platform; it never installs, configures or holds credentials for platform
components.

## What the platform provides

| Component | What you get | You never do |
|---|---|---|
| Kubernetes (Rancher Desktop, k3s) | A namespace: the shared `mcp-servers`, or your own | Create namespaces, set Pod Security, label for injection |
| Istio mesh (trust domain `cluster.local`) | A SPIFFE identity per service account (`spiffe://cluster.local/ns/<ns>/sa/<sa>`); STRICT mTLS in your namespace | Configure mTLS or certificates |
| Network isolation | Default-deny ingress; only the gateway can reach your pods (NetworkPolicy + mesh AuthorizationPolicy on the gateway's identity) | Write the baseline policies |
| agentgateway on `localhost:8000` | A shared Gateway with its own mesh identity, so it reaches your pods over mTLS | Run or configure the gateway itself |
| Keycloak realm `mcp` (issuer `http://localhost:8000/realms/mcp`: sign-in is published on the shared gateway, same origin as your MCP endpoint) | Your scopes and clients, created from your tenant file; their secrets written into your namespace | Use the Keycloak admin account |
| Realm security baseline | Brute-force protection, password policy, PKCE for every public client, consent, offline-token limits, login/refresh events, dynamic client registration for local MCP clients (e.g. MCP Inspector) | Harden the realm |
| SPIRE | Installed; becomes the mesh CA in a later phase | — |

All MCP servers share one cluster and one trust domain.

## What you own

In **your repo**:

1. Your MCP server and its Deployment, Service and ServiceAccount, in the namespace you chose.
2. Your gateway configuration, in your namespace:
   - an `AgentgatewayBackend` that selects your Service **by label** (`mcp.agentgateway.dev/expose: <your-server>`).
     A `static` host is sent in plaintext and is refused under STRICT mTLS;
   - an `HTTPRoute` on `agentgateway-proxy` (namespace `agentgateway-system`) for the paths you declared;
   - an `AgentgatewayPolicy` for your route (JWT in `Permissive` mode with `preserveToken: true`, rate limit, header
     hygiene, optional extAuth). Start from [mcp-route-template.yaml](mcp-route-template.yaml).
3. `platform/tenant.yaml`: what you need from the platform (format below).
4. Anything else your server needs (databases, queues): bring your own for now.

Your server validates tokens itself (issuer, audience = your resource URL, expiry, scopes) and serves its own OAuth
protected-resource metadata. The gateway's checks are defence in depth, not a replacement.

## The tenant file

```yaml
apiVersion: platform.mcp.lab/v1alpha1
kind: McpTenant
name: ecommerce                 # your tenant id (= the key the platform registers you under)
namespace: mcp-servers          # shared namespace, or a dedicated one the platform creates for you, e.g. `ecommerce`
gateway:
  paths: [/mcp, /approve, /.well-known/oauth-protected-resource]   # prefixes you own on localhost:8000
idp:
  resourceScopes:               # carries your audience; a token is valid at your server only if the client asked for it
  - name: shop:api
    audience: http://localhost:8000/mcp
    consentText: Browse the shop and keep a cart as you
  consentScopes:                # step-up consent for sensitive tools
  - name: ecommerce:checkout
    consentText: Let this app start purchases for you
  testClient:                   # attach your scopes to the platform's shared test client (mcp-test-client)
    defaultScopes: [shop:api]
    optionalScopes: [ecommerce:checkout]
  clients:
  - clientId: shop-approval     # confidential web client: authorization code + PKCE, no consent screen
    type: web
    redirectUris: [http://localhost:8000/approve/callback]
    secretKey: APPROVAL_CLIENT_SECRET
  - clientId: session-manager   # service account with realm-management roles from the platform allow-list
    type: service-account
    realmManagementRoles: [manage-users, view-users, query-users, view-events]
    secretKey: SM_CLIENT_SECRET
  secret:                       # Secret written into your namespace (client secrets + generated values)
    name: shop-secrets
    generated: [ADMIN_TOKEN]    # random, created once and kept
```

A complete example: [../examples/sample-tenant.yaml](../examples/sample-tenant.yaml). The live one:
`ecommerce-mcp-server/platform/tenant.yaml`.

Rules the platform enforces:

| Rule | Checked when |
|---|---|
| `kind: McpTenant`, `name` equals the registry key, `namespace` set | `terraform plan` |
| Gateway paths do not overlap another tenant's (prefix match, conservative) | `terraform plan` |
| Client ids and scope names are unique across tenants | `terraform plan` |
| A dedicated namespace belongs to one tenant | `terraform plan` |
| Platform and Keycloak built-ins (`mcp-test-client`, `admin-cli`, `openid`, `offline_access`, `mcp-groups`, …) cannot be claimed | onboarding (before any change) |
| Objects owned by another tenant (tag `mcp.platform/tenant`) cannot be modified | onboarding (before any change) |
| Service-account roles come from `var.tenant_allowed_admin_roles` (default `view-users`, `query-users`, `view-events`, `manage-users`) | onboarding (before any change) |
| Your scopes are optional for every client and allowed for dynamic registration; never realm defaults (a default would put your audience into every app's tokens) | applied by onboarding |

A refused tenant file changes nothing. Onboarding runs are serialised because several steps update shared realm
objects.

## Steps

1. **You:** write `platform/tenant.yaml` in your repo.
2. **Platform team:** register it in `terraform/environments/<env>/terraform.tfvars`:
   ```hcl
   tenants = {
     ecommerce = "../../ecommerce-mcp-server/platform/tenant.yaml"
     myserver  = "../../my-mcp-server/platform/tenant.yaml"
   }
   ```
   and run `terraform apply -var-file=environments/local/terraform.tfvars` (from `terraform/`). Re-run whenever a
   tenant file changes; it is idempotent.
3. **You:** build your image and `kubectl apply` your manifests. Your Secret is already in your namespace.
4. **You:** check it: `curl localhost:8000/.well-known/oauth-protected-resource/<your path>`, then an MCP client
   (e.g. MCP Inspector) against `http://localhost:8000/<your path>`.

`terraform output tenants` lists onboarded tenants and their namespaces.

## If something else must call your server

The baseline allows only the gateway. For another caller (another MCP server, a metrics scraper), add in your
namespace an Istio `AuthorizationPolicy` (`ALLOW`, the caller's principal) and a `NetworkPolicy` (ingress from the
caller's pods). Both are additive to the baseline.

## Limits (proof of concept)

- **No offboarding.** Removing a tenant from `tenants` deletes its dedicated namespace (with everything in it) but
  leaves its Keycloak scopes and clients. Remove those by hand.
- Paths share one host, `localhost:8000`. New tenants should use their own prefix, e.g. `/<tenant>/mcp`.
- `manage-users` is realm-wide (it can end any user's sessions). Production should scope it per tenant (Keycloak
  fine-grained admin permissions) or run the theft response as a platform service.
- Dedicated namespaces are PSA `privileged` (Istio sidecar init) until Istio CNI is installed.
- HTTP everywhere except gateway↔workload (mTLS). Sign-in is on the gateway (`/realms/mcp`, module `auth-route`); the
  Keycloak admin console is not published and is reached through a port-forward on `:8080`.
- Keep your MCP endpoint on the gateway's origin: some clients only fetch OAuth endpoints on the MCP server's own
  origin when it is a private address (OpenClaw), which is why sign-in lives there too.
