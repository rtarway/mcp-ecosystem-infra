# How MCP clients register and sign in

*Platform behaviour for every MCP server on the platform. Evidence: the ecommerce tenant's harness tests
(ecommerce-mcp-server `docs/HARNESSES.md`, `docs/CLIENT-COMPATIBILITY-REPORT.md`).*

## What clients see

1. **The 401 challenge.** The MCP server answers `401`; the header points to its protected-resource metadata.
2. **Metadata.** The protected-resource metadata names the realm `http://localhost:8000/realms/mcp` (served through
   the gateway: `modules/auth-route`).
3. **Dynamic client registration.** Clients register anonymously (RFC 7591) and sign in with Authorization Code +
   PKCE.

The authorization server's metadata (`scopes_supported`) lists **only scopes that anonymous registration accepts**:
- the allow-listed client scopes (each tenant's scopes, `openid`, `offline_access`);
- the realm default scopes.

Everything else (`service_account`, `microprofile-jwt`, `address`, `phone`, `organization`, …) is hidden from the
metadata by `modules/keycloak/scripts/realm-baseline.sh` (client-scope attribute
`include.in.openid.provider.metadata=false`). Reason: some clients register asking for every advertised scope (Codex),
and one refused scope fails the whole registration. Verified: Codex with no scope configuration registers and signs
in.

## Anonymous registration rules (lab)

| Rule | Setting |
|---|---|
| Redirect and client URIs | must be on `localhost`, `127.0.0.1` or `github.com` (trusted-hosts policy, URI half) |
| Sender address | not checked: behind the gateway and load balancer it is never the client's |
| Scopes a client may name | allow-list (tenant scopes are added by onboarding) |
| Public clients | PKCE S256, consent required, no implicit or password grant (client policy) |
| Max clients | Keycloak's cap; expired clients are removed by the expiry job (`modules/client-expiry`) |

## Findings from the S7 investigations (2026-10-26)

**A registered client cannot later ask for a scope it did not name at registration.** When the registration request
names scopes, Keycloak gives the client exactly those as optional scopes. A later authorization request for another
allowed scope fails with `invalid_scope`; Claude Code's step-up hit this. No built-in registration policy adds
scopes to a client. Consequence: MCP servers should advertise every scope a client will need, so clients register
with all of them (ecommerce does: report R2). A server that relies on step-up to a scope not yet registered needs
the client to register again.

**Client ID Metadata Documents (CIMD).** Keycloak 26.8 ships CIMD as an *experimental* feature (`CIMD`), disabled
by default. It could be enabled on the Keycloak CR (`spec.features.enabled`) for a trial. It is not enabled here:
- an experimental feature can change between releases;
- the lab has no public HTTPS origin where vendors' metadata documents could point back.

Revisit with the production design.

## Production path for clients with hosted callbacks

Some clients redirect to their vendor's HTTPS callback, not to loopback:
- Google Antigravity: `https://antigravity.google/oauth-callback`;
- claude.ai connectors: `https://claude.ai/api/mcp/auth_callback`.

Anonymous registration refuses those redirects by design. Not built locally, because it needs a public HTTPS
origin. Options:
- **CIMD** (above), so the vendor's domain identifies the client;
- **Pre-registered vendor clients** owned by the platform: one public client per vendor, with its callback,
  PKCE and consent. This is a platform registry, not a tenant one: today's tenant client types are `web` and
  `service-account` only.
