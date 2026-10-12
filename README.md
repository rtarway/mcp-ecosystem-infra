# MCP Platform — Local Infrastructure

The platform that MCP server teams deploy onto (local proof of concept on Rancher Desktop). It provides, already
secured: Kubernetes namespaces, the Istio mesh (one trust domain, `cluster.local`), SPIRE, the Keycloak identity
provider (realm `mcp`) and the agentgateway MCP gateway on `localhost:8000`.

**Application teams do not install or configure platform components.** A team builds its MCP server, keeps a
`platform/tenant.yaml` in its own repo (namespace, gateway paths, identity-provider scopes/clients), and the platform
team registers that file here. `terraform apply` then creates the team's namespace (if dedicated) with the security
baseline, and its scopes, clients and secrets, using the platform's own credentials. The team deploys its server and
gateway route into its namespace. Contract and steps: **[docs/onboarding.md](docs/onboarding.md)**.

Onboarded today: `ecommerce` (repo `ecommerce-mcp-server`, shared namespace `mcp-servers`).

## Architecture

```
   MCP clients (agents, MCP Inspector, …)            customer's browser (login, consent)
                  │                                              │
                  ▼  localhost:8000                              ▼  localhost:8080 (port-forward)
   ┌──────────────────────────────────────┐          ┌────────────────────────────────┐
   │ agentgateway (ns agentgateway-system)│          │ Keycloak (ns keycloak), realm  │
   │ shared Gateway · MCP-aware routing   │          │ `mcp` + security baseline +    │
   │ own SPIFFE identity (istiod)         │          │ per-tenant scopes and clients  │
   └──────────────────┬───────────────────┘          └────────────────────────────────┘
                      │ mTLS (gateway identity)
   ┌──────────────────┴──────────────────────────────────────────────────────────────┐
   │ Istio mesh, trust domain cluster.local                                          │
   │  ns mcp-servers (shared)          ns <tenant> (dedicated, optional)            │
   │  default-deny · STRICT mTLS ·     same baseline, created on onboarding          │
   │  only the gateway may call                                                       │
   │   MCP server A   MCP server B       MCP server C                                 │
   └──────────────────────────────────────────────────────────────────────────────────┘
   SPIRE (server + agent) installed; becomes the mesh CA in Phase 2b.
```

### Why agentgateway

An open-source (Linux Foundation) Gateway API data plane with native MCP routing: it terminates and multiplexes MCP
sessions, understands JSON-RPC methods and tool names, and integrates natively with Istio (its own SPIFFE identity,
mTLS to mesh workloads without a sidecar). An earlier plan used kgateway; agentgateway replaced it.

### Why not a fully "official" Keycloak Helm chart

The Keycloak project itself recommends the **Keycloak Operator** for production and does
not publish its own server Helm chart. We use the Operator (installed via its official
manifests, wrapped in Terraform's `kubectl`/`helm` providers) rather than a third-party
community chart, since you asked for official sources wherever possible.

## Prerequisites (manual — these are GUI/host-level installs Claude can't script)

1. **Rancher Desktop** — download and install for your OS:
   https://rancherdesktop.io/
   - Preferences → Container Engine: **dockerd (moby)** (you specified Docker, not containerd)
   - Preferences → Kubernetes: enable, version ≥ 1.30. Keep Traefik enabled: its CRD chart installs the
     Gateway API CRDs agentgateway needs (the gateway itself listens on 8000, so there is no port conflict)
   - Preferences → Virtual Machine → Resources: **6–8 vCPU / 16 GB RAM** (per your sizing)
2. **Terraform** ≥ 1.7
3. **kubectl**, **helm** ≥ 3.14 CLI (for verification/debugging alongside Terraform)
4. Confirm your kubecontext points at Rancher Desktop:
   ```bash
   kubectl config current-context   # should be "rancher-desktop"
   ```

## Layout

```
terraform/
  versions.tf          # required providers
  providers.tf          # helm + kubernetes provider config (reads local kubeconfig)
  variables.tf
  main.tf                # wires modules together, in dependency order
  modules/
    namespaces/          # all namespaces + baseline PodSecurity labels
    spire/                # SPIRE server + agent (SPIFFE identity for the mesh)
    istio/                # istio-base, istiod, ingress gateway (values only — CA
                           #  federation with SPIRE is a documented Phase 2b step, see
                           #  docs/phase-plan.md)
    keycloak/             # Keycloak Operator + CR (dev-mode Postgres), realm `mcp` import,
                          #  scripts/realm-baseline.sh: realm security baseline (applied on every change)
    agentgateway/         # agentgateway CRDs + control plane + shared Gateway :8000 with its own
                          #  SPIFFE identity from istiod (AgentgatewayParameters.istio)
    mcp-servers-baseline/ # security baseline for an MCP namespace (shared mcp-servers + every dedicated one)
    mcp-tenant/           # onboards one team from its tenant.yaml (namespace, IdP objects, secrets)
                          #  scripts/onboard_idp.py: validated, ownership-tagged, serialised
examples/
  sample-tenant.yaml      # starting point for a team's tenant.yaml
  environments/local/terraform.tfvars
docs/
  phase-plan.md           # what's built now vs. what's next
```

## Running it

```bash
cd terraform
terraform init
terraform plan  -var-file=environments/local/terraform.tfvars
terraform apply -var-file=environments/local/terraform.tfvars
```

Apply order is enforced via `depends_on`/implicit refs in `main.tf`:
namespaces → SPIRE → Istio → Keycloak (+ realm baseline) → agentgateway → mcp-servers baseline → tenants.

First apply will take 5–15 minutes (image pulls). Verify:

```bash
kubectl get pods -n spire-system
kubectl get pods -n istio-system
kubectl get pods -n keycloak
kubectl get pods -n agentgateway-system
kubectl get gatewayclass                 # agentgateway
terraform output tenants                 # onboarded MCP server teams and their namespaces
```

## What the platform guarantees every MCP server

Anything deployed into `mcp-servers` or a tenant's dedicated namespace inherits, with no per-server work:

| Guarantee | How | Module |
|---|---|---|
| Only the gateway can reach it | NetworkPolicy default-deny + allow only gateway proxy pods; STRICT mTLS; AuthorizationPolicy allowing only `spiffe://<mesh trust domain>/ns/agentgateway-system/sa/agentgateway-proxy` | `mcp-servers-baseline`, `agentgateway` |
| Headers the gateway sets can be trusted | follows from the above (each layer verified on its own) | — |
| Realm hardening | brute-force protection, password policy, offline tokens 7 d idle / 30 d max and not a default scope, login/refresh/registration events, every public client must use PKCE S256 (no implicit/password grants, consent required), dynamic registration for local clients only (lab), `groups` claim | `keycloak/scripts/realm-baseline.sh` |

What each MCP server still brings (example: `ecommerce-mcp-server`): its HTTPRoute + backend (label `selector`,
see `docs/mcp-route-template.yaml`), its edge `AgentgatewayPolicy`, its audience scope and clients in the realm
(the registration allow-list is merged, never overwritten), and any extra ALLOW policy if something other than the
gateway must call it.

Tenant guard-rails (`terraform plan` refuses, or onboarding refuses before changing anything): overlapping gateway
paths, duplicate client ids / scope names / dedicated namespaces across tenants, claiming platform or Keycloak
built-ins, modifying another tenant's objects, service-account roles outside `var.tenant_allowed_admin_roles`.

Caveats found while building on it:
- **Routes are not yet restricted to declared paths.** A team could apply an `HTTPRoute` for another team's path
  directly; an admission policy is the next step (see docs/onboarding.md).
- **The shared namespace is shared trust**: teams there can read each other's Secrets. Use a dedicated namespace for
  isolation.
- **agentgateway controller xDS certificate** expired ~24 h after the controller started and was not rotated: new
  gateway pods then fail readiness (`invalid peer certificate: certificate expired`). Workaround:
  `kubectl -n agentgateway-system rollout restart deploy/agentgateway`.
- **The gateway sends no client address upstream**; a tenant's edge policy stamps it (route template shows how).
- **No offboarding**: removing a tenant deletes its dedicated namespace but leaves its Keycloak objects.

## What's intentionally NOT done yet

See `docs/phase-plan.md`: SPIRE as the mesh CA, TLS everywhere, Istio CNI (so MCP namespaces can drop PSA
`privileged`), MFA for high-risk flows, no anonymous client registration outside the lab, an admission policy that
ties gateway routes to the paths each tenant declared, tenant offboarding, and shared data services (databases,
queues) for tenants, which bring their own for now.
