#!/usr/bin/env python3
"""Client and consent expiry for the shared realm (runs as a Kubernetes CronJob; stdlib only).

Every MCP client a customer links expires after MAX_AGE_SECONDS (default 30 days), so the customer's agent starts
over: registers again, signs in and consents again.
  * Self-registered clients (dynamic client registration: client id = Keycloak's generated id, no tenant owner) get a
    first-seen stamp on the first run that sees them, and are deleted once older than the limit. Deleting a client
    ends its tokens, sessions and consents. Keycloak records no creation date, hence the stamp: clients that existed
    before the job first ran age from that run.
  * Consents older than the limit (since last granted) are revoked for every user, whichever client they belong to;
    revoking also ends that client's offline tokens for the user.
Platform, tenant and built-in clients are never touched.

Env: KC_URL, REALM, CLIENT_ID, CLIENT_SECRET (this job's service account), MAX_AGE_SECONDS, DRY_RUN (true|false).
"""
import json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

KC = os.environ["KC_URL"].rstrip("/")
REALM = os.environ.get("REALM", "mcp")
MAX_AGE_MS = int(os.environ.get("MAX_AGE_SECONDS", str(30 * 86400))) * 1000
DRY = os.environ.get("DRY_RUN", "false").lower() == "true"
NOW = int(time.time() * 1000)
FIRST_SEEN = "mcp.platform/first-seen"
TENANT_OWNER = "mcp.platform/tenant"
GENERATED_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
PAGE = 200


def log(action, **detail):
    print(json.dumps({"job": "client-expiry", "action": action, "dryRun": DRY, **detail}), flush=True)


def _token():
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": os.environ["CLIENT_ID"], "client_secret": os.environ["CLIENT_SECRET"]}).encode()
    with urllib.request.urlopen(f"{KC}/realms/{REALM}/protocol/openid-connect/token", body, timeout=15) as r:
        return json.load(r)["access_token"]


TOKEN = _token()


def api(method, path, body=None):
    req = urllib.request.Request(f"{KC}/admin/realms/{REALM}{path}", method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def paged(path):
    first = 0
    while True:
        sep = "&" if "?" in path else "?"
        batch = api("GET", f"{path}{sep}first={first}&max={PAGE}") or []
        yield from batch
        if len(batch) < PAGE:
            return
        first += PAGE


def self_registered(c):
    attrs = c.get("attributes") or {}
    return c["clientId"] == c["id"] and bool(GENERATED_ID.match(c["clientId"])) and TENANT_OWNER not in attrs


days = lambda ms: round(ms / 86400_000, 2)
counts = {"stamped": 0, "client_deleted": 0, "consent_revoked": 0, "errors": 0}

# --- self-registered clients ---
for c in list(paged("/clients")):
    if not self_registered(c):
        continue
    seen = (c.get("attributes") or {}).get(FIRST_SEEN)
    try:
        if not seen:
            if not DRY:
                full = api("GET", f"/clients/{c['id']}")
                full["attributes"] = {**(full.get("attributes") or {}), FIRST_SEEN: str(NOW)}
                api("PUT", f"/clients/{c['id']}", full)
            counts["stamped"] += 1
            log("stamped", clientId=c["clientId"], name=c.get("name"))
        elif NOW - int(seen) > MAX_AGE_MS:
            if not DRY:
                api("DELETE", f"/clients/{c['id']}")
            counts["client_deleted"] += 1
            log("client_deleted", clientId=c["clientId"], name=c.get("name"), ageDays=days(NOW - int(seen)))
    except (urllib.error.HTTPError, ValueError) as e:
        counts["errors"] += 1
        log("error", clientId=c["clientId"], detail=str(e))

# --- consents ---
for u in paged("/users?briefRepresentation=true"):
    for consent in api("GET", f"/users/{u['id']}/consents") or []:
        granted = max(consent.get("createdDate") or 0, consent.get("lastUpdatedDate") or 0)
        if NOW - granted <= MAX_AGE_MS:
            continue
        try:
            if not DRY:
                api("DELETE", f"/users/{u['id']}/consents/{urllib.parse.quote(consent['clientId'], safe='')}")
            counts["consent_revoked"] += 1
            log("consent_revoked", user=u["id"], clientId=consent["clientId"], ageDays=days(NOW - granted))
        except urllib.error.HTTPError as e:
            counts["errors"] += 1
            log("error", user=u["id"], clientId=consent["clientId"], detail=str(e))

log("summary", maxAgeDays=days(MAX_AGE_MS), **counts)
sys.exit(1 if counts["errors"] else 0)
