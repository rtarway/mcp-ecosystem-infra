#!/usr/bin/env python3
"""Creates (idempotently) the expiry job's own Keycloak service account and stores its credentials in a Kubernetes
Secret next to the CronJob. Run by Terraform with the platform's admin credentials; tenants never get these roles.

Env: KC_URL, KC_ADMIN_PASSWORD, REALM, CLIENT_ID, NAMESPACE, SECRET_NAME. Stdlib only.
"""
import json, os, subprocess, sys, urllib.error, urllib.parse, urllib.request

KC = os.environ["KC_URL"].rstrip("/")
REALM = os.environ.get("REALM", "mcp")
CLIENT_ID = os.environ["CLIENT_ID"]
# Read users and clients, delete self-registered clients, revoke consents. Realm-wide by nature.
ROLES = ["view-users", "query-users", "manage-users", "view-clients", "query-clients", "manage-clients"]


def _token():
    body = urllib.parse.urlencode({"client_id": "admin-cli", "username": "admin", "password": os.environ["KC_ADMIN_PASSWORD"], "grant_type": "password"}).encode()
    with urllib.request.urlopen(f"{KC}/realms/master/protocol/openid-connect/token", body, timeout=15) as r:
        return json.load(r)["access_token"]


TOKEN = _token()


def api(method, path, body=None):
    req = urllib.request.Request(f"{KC}/admin/realms/{REALM}{path}", method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def client(client_id):
    return next(iter(api("GET", f"/clients?clientId={urllib.parse.quote(client_id)}") or []), None)


rep = {"clientId": CLIENT_ID, "name": "Platform: client and consent expiry", "enabled": True, "publicClient": False,
       "clientAuthenticatorType": "client-secret", "serviceAccountsEnabled": True, "standardFlowEnabled": False,
       "implicitFlowEnabled": False, "directAccessGrantsEnabled": False, "fullScopeAllowed": False,
       "attributes": {"mcp.platform/owner": "platform"}}
existing = client(CLIENT_ID)
if existing:
    api("PUT", f"/clients/{existing['id']}", {**existing, **rep, "attributes": {**(existing.get("attributes") or {}), **rep["attributes"]}})
else:
    api("POST", "/clients", rep)
    print(f"  created service account {CLIENT_ID}", file=sys.stderr)
uuid = client(CLIENT_ID)["id"]

sa_user = api("GET", f"/clients/{uuid}/service-account-user")["id"]
rm = client("realm-management")["id"]
have = {r["name"] for r in api("GET", f"/users/{sa_user}/role-mappings/clients/{rm}") or []}
wanted = [api("GET", f"/clients/{rm}/roles/{r}") for r in ROLES if r not in have]
if wanted:
    api("POST", f"/users/{sa_user}/role-mappings/clients/{rm}", wanted)
# fullScopeAllowed=false: the client's own token only carries roles in its scope, so add them there too.
scoped = {r["name"] for r in api("GET", f"/clients/{uuid}/scope-mappings/clients/{rm}") or []}
missing = [api("GET", f"/clients/{rm}/roles/{r}") for r in ROLES if r not in scoped]
if missing:
    api("POST", f"/clients/{uuid}/scope-mappings/clients/{rm}", missing)

secret = api("GET", f"/clients/{uuid}/client-secret")["value"]
manifest = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": os.environ["SECRET_NAME"], "namespace": os.environ["NAMESPACE"]},
            "stringData": {"CLIENT_ID": CLIENT_ID, "CLIENT_SECRET": secret}}
subprocess.run(["kubectl", "apply", "-f", "-"], input=json.dumps(manifest), text=True, check=True, capture_output=True)
print(f"  credentials in {os.environ['NAMESPACE']}/{os.environ['SECRET_NAME']}", file=sys.stderr)
