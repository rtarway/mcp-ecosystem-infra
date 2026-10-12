#!/usr/bin/env python3
"""Applies one tenant's identity-provider needs (the `idp` section of its tenant.yaml) to the shared realm.

Run by Terraform (modules/mcp-tenant) with the platform's admin credentials, so application teams never hold them.
Idempotent. Multi-tenant safe:
  * every client and client scope it creates is tagged `mcp.platform/tenant=<tenant>`; objects owned by another
    tenant, and the platform's / Keycloak's built-ins, are never modified (onboarding fails instead);
  * shared allow-lists (dynamic-registration scopes, realm optional scopes) are merged, never overwritten;
  * service accounts may only receive realm-management roles on the platform allow-list.

Env: KC_URL, KC_ADMIN_PASSWORD, REALM, TENANT, TENANT_NAMESPACE, TENANT_SPEC (JSON of the tenant's `idp` section),
     ALLOWED_ADMIN_ROLES (comma-separated). Stdlib only.
"""
import base64, fcntl, json, os, secrets, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request

KC = os.environ["KC_URL"].rstrip("/")
REALM = os.environ.get("REALM", "mcp")
TENANT = os.environ["TENANT"]
NAMESPACE = os.environ["TENANT_NAMESPACE"]
SPEC = json.loads(os.environ["TENANT_SPEC"] or "{}")
ALLOWED_ROLES = {r for r in os.environ.get("ALLOWED_ADMIN_ROLES", "").split(",") if r}
OWNER = "mcp.platform/tenant"

RESERVED_CLIENTS = {"account", "account-console", "admin-cli", "broker", "realm-management", "security-admin-console", "mcp-test-client"}
RESERVED_SCOPES = {"openid", "profile", "email", "roles", "web-origins", "acr", "basic", "offline_access", "address", "phone",
                   "microprofile-jwt", "organization", "service_account", "role_list", "saml_organization", "mcp-groups"}


def log(msg):
    print(f"  [{TENANT}] {msg}", file=sys.stderr)


def fail(msg):
    sys.exit(f"tenant {TENANT}: {msg}")


def _token():
    body = urllib.parse.urlencode({"client_id": "admin-cli", "username": "admin", "password": os.environ["KC_ADMIN_PASSWORD"], "grant_type": "password"}).encode()
    with urllib.request.urlopen(f"{KC}/realms/master/protocol/openid-connect/token", body, timeout=15) as r:
        return json.load(r)["access_token"]


# Tenants are onboarded in parallel by Terraform, and several steps read-modify-write SHARED realm objects (the
# dynamic-registration allow-list, realm optional scopes). Serialise runs so no tenant's update is lost.
_lock = open(os.path.join(tempfile.gettempdir(), f"mcp-platform-idp-{REALM}.lock"), "w")
fcntl.flock(_lock, fcntl.LOCK_EX)

TOKEN = _token()


def api(method, path, body=None, ok=(200, 201, 204)):
    req = urllib.request.Request(f"{KC}/admin/realms/{REALM}{path}", method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return None
        fail(f"{method} {path} -> HTTP {e.code}: {e.read()[:300]!r}")


def owned_by_us(obj, kind, name, reserved):
    """Claims an object for this tenant, or refuses if it belongs to someone else."""
    if name in reserved:
        fail(f"{kind} '{name}' is reserved by the platform")
    owner = (obj.get("attributes") or {}).get(OWNER)
    if owner and owner != TENANT:
        fail(f"{kind} '{name}' belongs to tenant '{owner}'")
    return owner == TENANT


# ------------------------------------------------------------------------- validate everything before writing
def validate():
    """Refuses the whole spec up front, so a bad entry never leaves half-created objects behind."""
    problems = []
    names = [s["name"] for s in SPEC.get("resourceScopes", []) + SPEC.get("consentScopes", [])]
    existing_scopes = {s["name"]: s for s in api("GET", "/client-scopes")}
    for n in names:
        if n in RESERVED_SCOPES:
            problems.append(f"client scope '{n}' is reserved by the platform")
        owner = ((existing_scopes.get(n) or {}).get("attributes") or {}).get(OWNER)
        if owner and owner != TENANT:
            problems.append(f"client scope '{n}' belongs to tenant '{owner}'")
    for s in SPEC.get("resourceScopes", []):
        if not s.get("audience"):
            problems.append(f"resource scope '{s['name']}' needs an audience")
    for key in ("defaultScopes", "optionalScopes"):
        for n in (SPEC.get("testClient") or {}).get(key, []):
            if n not in names:
                problems.append(f"testClient.{key}: '{n}' is not one of this tenant's scopes")
    for c in SPEC.get("clients", []):
        cid = c.get("clientId", "")
        if cid in RESERVED_CLIENTS:
            problems.append(f"client '{cid}' is reserved by the platform")
        if c.get("type") not in ("web", "service-account"):
            problems.append(f"client {cid}: unknown type '{c.get('type')}' (web | service-account)")
        if c.get("type") == "web" and not c.get("redirectUris"):
            problems.append(f"client {cid}: web clients need redirectUris")
        denied = set(c.get("realmManagementRoles", [])) - ALLOWED_ROLES
        if denied:
            problems.append(f"client {cid}: realm-management roles not allowed for tenants: {sorted(denied)}")
        found = next(iter(api("GET", f"/clients?clientId={urllib.parse.quote(cid)}")), None)
        owner = ((found or {}).get("attributes") or {}).get(OWNER)
        if owner and owner != TENANT:
            problems.append(f"client '{cid}' belongs to tenant '{owner}'")
    if problems:
        fail("refused, nothing changed:\n  - " + "\n  - ".join(problems))


validate()

# ---------------------------------------------------------------------------------------------- client scopes
def scope_by_name(name):
    return next((s for s in api("GET", "/client-scopes") if s["name"] == name), None)


def ensure_scope(name, attrs, mappers):
    attrs = {**attrs, OWNER: TENANT}
    existing = scope_by_name(name)
    if existing:
        owned_by_us(existing, "client scope", name, RESERVED_SCOPES)
        existing["attributes"] = {**(existing.get("attributes") or {}), **attrs}
        api("PUT", f"/client-scopes/{existing['id']}", existing)
        sid = existing["id"]
        have = {m["name"] for m in existing.get("protocolMappers") or []}
        for m in mappers:
            if m["name"] not in have:
                api("POST", f"/client-scopes/{sid}/protocol-mappers/models", m)
    else:
        if name in RESERVED_SCOPES:
            fail(f"client scope '{name}' is reserved by the platform")
        api("POST", "/client-scopes", {"name": name, "protocol": "openid-connect", "attributes": attrs, "protocolMappers": mappers})
        sid = scope_by_name(name)["id"]
        log(f"created client scope {name}")
    return sid


scope_ids = {}
for s in SPEC.get("resourceScopes", []):
    # An audience-carrying scope: tokens get `aud=<audience>` only when a client asks for this scope.
    scope_ids[s["name"]] = ensure_scope(
        s["name"],
        {"include.in.token.scope": "true", "display.on.consent.screen": "true", "consent.screen.text": s.get("consentText", "")},
        [{"name": f"{s['name']}-audience", "protocol": "openid-connect", "protocolMapper": "oidc-audience-mapper",
          "config": {"included.custom.audience": s["audience"], "access.token.claim": "true", "id.token.claim": "false"}}])
for s in SPEC.get("consentScopes", []):
    scope_ids[s["name"]] = ensure_scope(
        s["name"], {"include.in.token.scope": "true", "display.on.consent.screen": "true", "consent.screen.text": s.get("consentText", "")}, [])

# Offered (optional) to every client, so dynamically registered MCP clients can request them. Never realm defaults:
# a default would put this tenant's audience into every app's tokens.
defaults = {s["id"] for s in api("GET", "/default-default-client-scopes")}
optionals = {s["id"] for s in api("GET", "/default-optional-client-scopes")}
for name, sid in scope_ids.items():
    if sid in defaults:
        api("DELETE", f"/default-default-client-scopes/{sid}")
    if sid not in optionals:
        api("PUT", f"/default-optional-client-scopes/{sid}")

# Anonymous dynamic registration may request them (merged into the platform's allow-list).
comps = api("GET", "/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy")
comp = next(c for c in comps if c["subType"] == "anonymous" and c["providerId"] == "allowed-client-templates")
cfg = comp.setdefault("config", {})
cfg["allowed-client-scopes"] = sorted(set(cfg.get("allowed-client-scopes", [])) | set(scope_ids))
api("PUT", f"/components/{comp['id']}", comp)
if scope_ids:
    log(f"scopes {', '.join(scope_ids)}: optional for all clients, allowed for dynamic registration")

# ----------------------------------------------------------------------------- the platform's shared test client
tc_spec = SPEC.get("testClient") or {}
if tc_spec:
    tc = next(iter(api("GET", "/clients?clientId=mcp-test-client")), None)
    if tc:
        for kind, key in (("default", "defaultScopes"), ("optional", "optionalScopes")):
            for name in tc_spec.get(key, []):
                if name not in scope_ids:
                    fail(f"testClient.{key}: '{name}' is not one of this tenant's scopes")
                api("PUT", f"/clients/{tc['id']}/{kind}-client-scopes/{scope_ids[name]}")
        log("mcp-test-client: tenant scopes attached")


# --------------------------------------------------------------------------------------------- tenant clients
def client_by_id(client_id):
    return next(iter(api("GET", f"/clients?clientId={urllib.parse.quote(client_id)}")), None)


secret_values = {}
for c in SPEC.get("clients", []):
    cid, ctype = c["clientId"], c["type"]
    base = {"clientId": cid, "enabled": True, "publicClient": False, "clientAuthenticatorType": "client-secret",
            "implicitFlowEnabled": False, "directAccessGrantsEnabled": False, "fullScopeAllowed": False}
    if ctype == "web":
        # Confidential web client (e.g. a server-rendered page that re-authenticates the user): code + PKCE.
        rep = {**base, "standardFlowEnabled": True, "serviceAccountsEnabled": False, "consentRequired": False,
               "redirectUris": c["redirectUris"], "webOrigins": [],
               "attributes": {"pkce.code.challenge.method": "S256", "post.logout.redirect.uris": "+", OWNER: TENANT}}
    elif ctype == "service-account":
        rep = {**base, "standardFlowEnabled": False, "serviceAccountsEnabled": True, "attributes": {OWNER: TENANT}}
    else:
        fail(f"client {cid}: unknown type '{ctype}' (web | service-account)")
    existing = client_by_id(cid)
    if existing:
        owned_by_us(existing, "client", cid, RESERVED_CLIENTS)
        api("PUT", f"/clients/{existing['id']}", {**existing, **rep, "attributes": {**(existing.get("attributes") or {}), **rep["attributes"]}})
        uuid = existing["id"]
    else:
        if cid in RESERVED_CLIENTS:
            fail(f"client '{cid}' is reserved by the platform")
        api("POST", "/clients", rep)
        uuid = client_by_id(cid)["id"]
        log(f"created {ctype} client {cid}")
    if ctype == "service-account":
        wanted = set(c.get("realmManagementRoles", []))
        denied = wanted - ALLOWED_ROLES
        if denied:
            fail(f"client {cid}: realm-management roles not allowed for tenants: {sorted(denied)}")
        sa = api("GET", f"/clients/{uuid}/service-account-user")
        rm = client_by_id("realm-management")
        roles = [r for r in api("GET", f"/clients/{rm['id']}/roles") if r["name"] in wanted]
        if roles:
            api("POST", f"/users/{sa['id']}/role-mappings/clients/{rm['id']}", roles)
            # fullScopeAllowed is off (least privilege), so assigned roles only reach the token through an explicit
            # scope mapping. Without it the service account authenticates but every admin call answers 403.
            api("POST", f"/clients/{uuid}/scope-mappings/clients/{rm['id']}", roles)
        log(f"{cid}: service account roles {sorted(wanted) or 'none'}")
    if c.get("secretKey"):
        secret_values[c["secretKey"]] = api("GET", f"/clients/{uuid}/client-secret")["value"]

# ------------------------------------------------------------------------------- secrets -> tenant namespace
sec = SPEC.get("secret")
if sec:
    name = sec["name"]
    current = subprocess.run(["kubectl", "-n", NAMESPACE, "get", "secret", name, "-o", "json"], capture_output=True, text=True)
    old = json.loads(current.stdout).get("data", {}) if current.returncode == 0 else {}
    for key in sec.get("generated", []):
        # Generated once and kept: rotating would silently break whoever already uses it.
        secret_values[key] = base64.b64decode(old[key]).decode() if key in old else secrets.token_urlsafe(30)
    manifest = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": {"name": name, "namespace": NAMESPACE, "labels": {OWNER: TENANT, "app.kubernetes.io/managed-by": "mcp-platform"}},
                "stringData": secret_values}
    subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(manifest), text=True, check=True, capture_output=True)
    log(f"secret {NAMESPACE}/{name}: {', '.join(sorted(secret_values))}")

print(f"tenant {TENANT}: identity provider configured")
