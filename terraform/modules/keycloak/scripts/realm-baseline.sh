#!/usr/bin/env bash
# Security baseline for the shared `mcp` realm. Idempotent; safe to re-run. App-agnostic: each MCP server adds
# its own scopes and clients from its own repo (allow-lists here are MERGED, never overwritten).
#   - brute-force protection, password policy
#   - offline (long-lived) refresh tokens: hard max + idle limit; offline_access not a realm default
#   - login/refresh/registration events on (theft detectors read REFRESH_TOKEN_ERROR "reuse" events)
#   - client policy: every public client must use PKCE S256; no implicit or password grants; consent required
#   - dynamic client registration (RFC 7591) for LOCAL clients only (lab): loopback redirect URIs, browser origins
#     (MCP Inspector), base allowed scopes, `mcp-groups` claim
#   - optional: prune dynamically registered clients (PRUNE_DCR_CLIENTS=true)
# Usage: KC_ADMIN_PASSWORD=... [KC_URL=http://localhost:8080] [REALM=mcp] realm-baseline.sh
set -euo pipefail
KC_URL="${KC_URL:-http://localhost:8080}"
REALM="${REALM:-mcp}"
OFFLINE_MAX_DAYS="${OFFLINE_MAX_DAYS:-30}"
OFFLINE_IDLE_DAYS="${OFFLINE_IDLE_DAYS:-7}"
: "${KC_ADMIN_PASSWORD:?set KC_ADMIN_PASSWORD}"

json() { python3 -c "import sys,json;d=json.load(sys.stdin);$1"; }
TOKEN=$(curl -sf -d client_id=admin-cli -d username=admin --data-urlencode "password=$KC_ADMIN_PASSWORD" \
  -d grant_type=password "$KC_URL/realms/master/protocol/openid-connect/token" | json "print(d['access_token'])")
api() { local m=$1 p=$2; shift 2; curl -sf -X "$m" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$KC_URL/admin/realms/$REALM$p" "$@"; }
log() { echo "  $*" >&2; }
scope_id() { api GET "/client-scopes" | json "print(next((s['id'] for s in d if s['name']=='$1'),''))"; }
client_uuid() { api GET "/clients?clientId=$1" | json "print(d[0]['id'] if d else '')"; }
in_list() { case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

# --- realm settings ---
REALM_JSON=$(api GET "" | json "
d.update(
  bruteForceProtected=True, permanentLockout=False, failureFactor=5, waitIncrementSeconds=60,
  maxFailureWaitSeconds=900, maxDeltaTimeSeconds=43200, quickLoginCheckMilliSeconds=1000, minimumQuickLoginWaitSeconds=60,
  passwordPolicy='length(12) and notUsername and notEmail',
  offlineSessionMaxLifespanEnabled=True, offlineSessionMaxLifespan=$OFFLINE_MAX_DAYS*86400, offlineSessionIdleTimeout=$OFFLINE_IDLE_DAYS*86400,
  eventsEnabled=True, eventsExpiration=604800, adminEventsEnabled=True, adminEventsDetailsEnabled=False,
  enabledEventTypes=['LOGIN','LOGIN_ERROR','LOGOUT','CODE_TO_TOKEN','CODE_TO_TOKEN_ERROR','REFRESH_TOKEN','REFRESH_TOKEN_ERROR','CLIENT_REGISTER','CLIENT_REGISTER_ERROR','GRANT_CONSENT','REVOKE_GRANT','UPDATE_CONSENT'],
)
print(json.dumps(d))")
api PUT "" -d "$REALM_JSON" >/dev/null
log "brute force (5 failures -> 1..15 min), password policy, offline max ${OFFLINE_MAX_DAYS}d / idle ${OFFLINE_IDLE_DAYS}d, events on"

# --- offline_access: not handed out by default ---
OFFLINE_ID=$(scope_id offline_access)
OPTS=$(api GET "/default-optional-client-scopes" | json "print(' '.join(s['id'] for s in d))")
if [ -n "$OFFLINE_ID" ] && in_list "$OFFLINE_ID" "$OPTS"; then api DELETE "/default-optional-client-scopes/$OFFLINE_ID" >/dev/null; log "offline_access removed from realm default optional scopes"; fi
TC=$(client_uuid mcp-test-client)
if [ -n "$OFFLINE_ID" ] && [ -n "$TC" ]; then api DELETE "/clients/$TC/optional-client-scopes/$OFFLINE_ID" >/dev/null 2>&1 || true; fi

# --- `groups` claim for gateway authorization rules (realm default) ---
GROUPS_ID=$(scope_id mcp-groups)
if [ -z "$GROUPS_ID" ]; then
  api POST "/client-scopes" -d '{"name":"mcp-groups","protocol":"openid-connect",
   "attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"},
   "protocolMappers":[{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
     "config":{"claim.name":"groups","full.path":"false","access.token.claim":"true","id.token.claim":"true","userinfo.token.claim":"true"}}]}' >/dev/null
  GROUPS_ID=$(scope_id mcp-groups); log "created client scope mcp-groups"
fi
DEFS=$(api GET "/default-default-client-scopes" | json "print(' '.join(s['id'] for s in d))")
in_list "$GROUPS_ID" "$DEFS" || api PUT "/default-default-client-scopes/$GROUPS_ID" >/dev/null
[ -n "$TC" ] && api PUT "/clients/$TC/default-client-scopes/$GROUPS_ID" >/dev/null

# --- client policy: public clients ---
# NB: every executor needs an explicit config; reject-ropc-grant with {} makes Keycloak 26.8 throw on every
# dynamic registration (HTTP 500).
api PUT "/client-policies/profiles" -d '{"profiles":[{
  "name":"public-client-baseline","description":"PKCE S256, no implicit or password grants, user consent",
  "executors":[
    {"executor":"pkce-enforcer","configuration":{"auto-configure":true}},
    {"executor":"reject-implicit-grant","configuration":{"auto-configure":true}},
    {"executor":"reject-ropc-grant","configuration":{"auto-configure":false}},
    {"executor":"consent-required","configuration":{"auto-configure":true}}]}]}' >/dev/null
api PUT "/client-policies/policies" -d '{"policies":[{
  "name":"public-clients-baseline","description":"Applies to every public client, including dynamically registered ones",
  "enabled":true,
  "conditions":[{"condition":"client-access-type","configuration":{"type":["public"]}}],
  "profiles":["public-client-baseline"]}]}' >/dev/null
log "client policy: public clients need PKCE S256 + consent; implicit and password grants rejected"

# --- dynamic client registration for local clients (merge, never shrink what apps added) ---
# merge_policy <providerId> <config key> <values...>
merge_policy() {
  local provider=$1 key=$2; shift 2
  local comp; comp=$(api GET "/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
    | json "print(json.dumps(next(x for x in d if x['subType']=='anonymous' and x['providerId']=='$provider')))")
  local id; id=$(json "print(d['id'])" <<<"$comp")
  local add; add=$(python3 -c "import json,sys;print(json.dumps(sys.argv[1:]))" "$@")
  api PUT "/components/$id" -d "$(json "c=d.setdefault('config',{});c['$key']=sorted(set(c.get('$key',[]))|set($add));print(json.dumps(d))" <<<"$comp")" >/dev/null
}
# github.com: MCP Inspector registers with client_uri=https://github.com/modelcontextprotocol/inspector and Keycloak
# requires every registered URL to match a trusted host. Lab trade-off; production disables anonymous DCR.
merge_policy trusted-hosts trusted-hosts localhost 127.0.0.1 github.com
# The sender-address half of the policy is off: registration arrives through the shared gateway (modules/auth-route),
# and behind a load balancer the address is the balancer's (Rancher's ServiceLB rewrites it), never the client's.
# The half that matters stays on: every registered redirect/client URI must be on a trusted host (loopback here).
set_policy() {
  local provider=$1 key=$2 value=$3
  local comp; comp=$(api GET "/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
    | json "print(json.dumps(next(x for x in d if x['subType']=='anonymous' and x['providerId']=='$provider')))")
  local id; id=$(json "print(d['id'])" <<<"$comp")
  api PUT "/components/$id" -d "$(json "d.setdefault('config',{})['$key']=['$value'];print(json.dumps(d))" <<<"$comp")" >/dev/null
}
set_policy trusted-hosts host-sending-registration-request-must-match false
set_policy trusted-hosts client-uris-must-match true
merge_policy registration-web-origins web-origins http://localhost:6274 http://127.0.0.1:6274 http://localhost:6277 http://127.0.0.1:6277
# offline_access may be NAMED at registration (clients do so because Keycloak advertises it). It is then granted,
# bounded by the offline lifetimes above. Refusing it breaks MCP Inspector's registration (HTTP 403).
merge_policy allowed-client-templates allowed-client-scopes openid offline_access
log "DCR: redirect URIs on localhost/github.com only (sender address not checked), Inspector origins allowed, base scopes openid/offline_access"

# --- advertise only what anonymous registration accepts ---
# Some clients (Codex) register asking for every scope in the authorization server's metadata; a scope the
# registration policy refuses (service_account, microprofile-jwt, ...) then fails the whole registration. Hide every
# scope that is neither an allowed client scope nor a realm default from the metadata. Scopes stay usable by
# clients configured for them; tenant scopes added later are allow-listed by onboarding and stay advertised.
ALLOWED=$(api GET "/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy" \
  | json "print(' '.join(next(x for x in d if x['subType']=='anonymous' and x['providerId']=='allowed-client-templates')['config'].get('allowed-client-scopes',[])))")
DEFAULTS=$(api GET "/default-default-client-scopes" | json "print(' '.join(c['name'] for c in d))")
HIDDEN=""
for row in $(api GET "/client-scopes" | json "[print(c['id']+'|'+c['name']) for c in d if c.get('protocol')=='openid-connect']"); do
  id=${row%%|*}; name=${row#*|}
  case " $ALLOWED $DEFAULTS " in *" $name "*) continue ;; esac
  rep=$(api GET "/client-scopes/$id" | json "d.setdefault('attributes',{})['include.in.openid.provider.metadata']='false';print(json.dumps(d))")
  api PUT "/client-scopes/$id" -d "$rep" >/dev/null
  HIDDEN="$HIDDEN $name"
done
log "metadata: hidden scopes registration would refuse:${HIDDEN:- none}"

if [ "${PRUNE_DCR_CLIENTS:-false}" = "true" ]; then
  N=0
  for id in $(api GET "/clients" | json "
import re
print(' '.join(c['id'] for c in d if re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', c['clientId'])))"); do
    api DELETE "/clients/$id" >/dev/null && N=$((N+1))
  done
  log "pruned $N dynamically registered client(s)"
fi
echo "realm $REALM: security baseline applied"
