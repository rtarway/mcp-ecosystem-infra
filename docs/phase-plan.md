# Phase Plan

## Phase 1 — Platform (this delivery)
- [x] Rancher Desktop prerequisites documented
- [x] Namespaces + PodSecurity baseline
- [x] SPIRE server + agent (SPIFFE identities, not yet wired to Istio as CA)
- [x] Istio base/istiod/ingressgateway (default Citadel CA — SPIRE federation pending)
- [x] Keycloak Operator + CR (HTTP only, no realm/clients yet)
- [x] agentgateway control plane + Gateway API CRDs (no routes/policies yet)

## Phase 2 — Identity plumbing
- [ ] 2a. `ClusterSPIFFEID` CRs (via spire-controller-manager) defining SPIFFE ID
      templates per workload (e.g. `spiffe://mcp.lab.internal/ns/{ns}/sa/{sa}`)
- [ ] 2b. Istio ↔ SPIRE CA federation: mount the SPIRE Workload API UDS into
      istio-proxy sidecars via the SPIFFE CSI driver, disable istiod's own CA issuance,
      configure `CA_PROVIDER`/SDS so mesh mTLS certs are SPIRE-issued SVIDs. This is the
      trickiest integration point in the whole stack — do it in isolation with a
      throwaway test workload before touching anything real.
- [ ] 2c. Verify with `istioctl proxy-config secret <pod>` that certs show the SPIRE
      trust domain and a SPIFFE URI SAN.

## Phase 3 — Keycloak OAuth 2.1 configuration
- [x] Realm for the MCP ecosystem (realm `mcp`, client `mcp-test-client`, DCR, device flow, PKCE, aud + groups claims), with:
  - Dynamic Client Registration (RFC 7591/7592) enabled
  - Device Authorization Grant (device code flow) enabled per client
  - Authorization Code + PKCE enforced (public clients: PKCE mandatory, confidential:
    still recommended under OAuth 2.1)
  - Token Exchange (RFC 8693) enabled — Keycloak supports this as a preview/organized
    feature; the exact client scope/permission config needed to allow a "standard token
    exchange" (audience-restricted downstream tokens) needs to be set per client
  - Refresh token rotation, short-lived access tokens, audience restriction per MCP server
- [x] Realm security baseline (`modules/keycloak/scripts/realm-baseline.sh`): brute force, password policy,
      offline-token limits, events, public-client PKCE policy, DCR policies for local clients
- [ ] MFA (OTP/WebAuthn) for high-risk flows (per-app authentication flow bindings)
- [ ] Production stance for registration: no anonymous DCR; CIMD with verified publisher or allowlist
- [ ] TLS in front of Keycloak (currently HTTP-only for bootstrap simplicity — must fix
      before any external client touches this, since OAuth 2.1 mandates TLS)

## Phase 4 — agentgateway routing + auth enforcement
- [ ] `Gateway` + `HTTPRoute`/MCP-route resources per MCP server
- [ ] JWT validation `TrafficPolicy` pointed at Keycloak's JWKS endpoint
- [ ] RFC 8693 token-exchange policy at the edge (incoming Keycloak-issued token →
      scoped, audience-restricted downstream token per MCP server) — this is the
      Wasm/EnvoyExtensionPolicy pattern referenced in agentgateway/Envoy AI Gateway docs;
      needs its own design pass given how new this capability is
- [x] Rate limiting per client address (per-route, owned by each MCP server; see docs/mcp-route-template.yaml)
- [ ] Client address preservation at the real load balancer (lab NAT hides it)

## Phase 5 — MCP servers
- [ ] Deploy actual MCP servers into `mcp-servers` namespace (mesh-injected, SPIFFE
      identity per server)
- [ ] Wire external client → agentgateway → (token validated/exchanged) → Istio mTLS →
      MCP server, end to end
- [x] AuthorizationPolicy (Istio) for service-to-service restrictions as defense in depth
      behind the gateway's own authz (`modules/mcp-servers-baseline`: default-deny NetworkPolicy, STRICT mTLS,
      only the gateway's SPIFFE identity; gateway identity via `AgentgatewayParameters.istio`)
- [ ] Istio CNI so `mcp-servers` can drop PSA `privileged`

Each phase should be its own Terraform apply / PR so a failure in, say, the SPIRE↔Istio
federation doesn't block you from having a working Keycloak to develop against.
