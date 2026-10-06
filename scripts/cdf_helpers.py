"""JSON helpers for cdf-group-setup.sh. Reads an API response on stdin."""

import json
import sys

GREEN, RED, RESET = "\033[32m", "\033[31m", "\033[0m"


_RAW = ""


def _load():
    global _RAW
    _RAW = sys.stdin.read()
    try:
        return json.loads(_RAW)
    except json.JSONDecodeError:
        return None


def error_message(doc, fallback="unexpected response"):
    if not isinstance(doc, dict):
        snippet = " ".join(_RAW.split())[:200]
        return f"{fallback}: {snippet}" if snippet else fallback
    err = doc.get("error")
    if isinstance(err, dict):
        return err.get("message") or json.dumps(err)[:300]
    return json.dumps(doc)[:300]


def check_access(project):
    """Exit 0 only if the token can create groups in this project."""
    doc = _load()
    if doc is None or "capabilities" not in doc:
        print(f"  CDF rejected the token: {error_message(doc)}")
        return 1
    reachable = [p["projectUrlName"] for p in doc.get("projects", [])]
    if project not in reachable:
        print(f"  token has no access to project '{project}' (reachable: {reachable or 'none'})")
        return 1
    for cap in doc.get("capabilities", []):
        acl = cap.get("groupsAcl")
        if acl and "CREATE" in acl.get("actions", []):
            return 0
    print("  no groupsAcl:CREATE in your effective access")
    return 1


def find_group(source_id, name):
    """Print '<id>\\t<name>\\t<sourceId|name>' for a conflicting or existing group."""
    doc = _load() or {}
    for group in doc.get("items", []):
        if group.get("sourceId") == source_id:
            print(f"{group['id']}\t{group['name']}\tsourceId")
            return 0
    for group in doc.get("items", []):
        if group.get("name") == name:
            print(f"{group['id']}\t{group['name']}\tname")
            return 0
    return 0


def build_body(name, source_id, caps_file):
    with open(caps_file) as handle:
        capabilities = json.load(handle)
    print(json.dumps({"items": [{"name": name, "sourceId": source_id, "capabilities": capabilities}]}))
    return 0


def created_id():
    doc = _load()
    items = (doc or {}).get("items")
    if not items:
        print(error_message(doc, "no group returned"), file=sys.stderr)
        return 1
    print(items[0]["id"])
    return 0


def show_group(group_id, source_id):
    doc = _load() or {}
    group = next((g for g in doc.get("items", []) if g["id"] == int(group_id)), None)
    if group is None:
        print(f"  {RED}✗{RESET} group not found after creation")
        return 1
    print(f"  {GREEN}✓{RESET} group '{group['name']}' exists")
    linked = group.get("sourceId") == source_id
    mark = GREEN + "✓" + RESET if linked else RED + "✗" + RESET
    print(f"  {mark} linked to Entra group {source_id}")
    for cap in group.get("capabilities", []):
        for acl, body in cap.items():
            print(f"  {GREEN}✓{RESET} {acl}: {','.join(body.get('actions', []))}")
    return 0 if linked else 1


def show_access(project):
    """Report what a token can actually reach. Exit 1 if it cannot use `project`."""
    doc = _load()
    if doc is None:
        print(f"  {RED}x{RESET} {error_message(doc)}")
        return 1
    print(f"  subject {doc.get('subject', '?')}")
    reachable = [p["projectUrlName"] for p in doc.get("projects", [])]
    if project not in reachable:
        print(f"  {RED}x{RESET} no access to '{project}' (reachable: {reachable or 'none'})")
        print("     No CDF group matches this principal's Entra groups.")
        return 1
    groups = next(p["groups"] for p in doc["projects"] if p["projectUrlName"] == project)
    print(f"  {GREEN}v{RESET} access to '{project}' via CDF group ids {groups}")
    caps = [(k, v.get("actions", [])) for c in doc.get("capabilities", []) for k, v in c.items() if k.endswith("Acl")]
    if not caps:
        print(f"  {RED}x{RESET} token carries no capabilities")
        return 1
    print(f"  {GREEN}v{RESET} capabilities:")
    for name, actions in sorted(caps):
        print(f"      {name}: {', '.join(actions)}")
    return 0


def list_groups():
    """Print every CDF group with its sourceId, to spot broken links."""
    doc = _load() or {}
    items = doc.get("items", [])
    if not items:
        print("  (no groups, or no permission to list them)")
        return 0
    for g in items:
        print(f"  id={g['id']:<12} name={g.get('name','?'):<30} sourceId={g.get('sourceId') or '(none)'}")
    return 0


def show_claims():
    """Decode the token's claims. Prints no secret — only claim names and group ids."""
    doc = _load() or {}
    token = doc.get("access_token", "")
    if not token:
        print(f"  {RED}x{RESET} no access_token in response: {error_message(doc)}")
        return 1
    import base64

    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    print(f"  audience : {claims.get('aud')}")
    print(f"  object id: {claims.get('oid')}")
    print(f"  claims   : {', '.join(sorted(claims))}")
    groups = claims.get("groups")
    if groups:
        print(f"  {GREEN}v{RESET} groups claim present: {groups}")
        return 0
    print(f"  {RED}x{RESET} NO groups claim — CDF cannot map this token to any group.")
    print("     Causes: groupMembershipClaims not set on the app registration, the service")
    print("     principal is not in any security group, or the token predates the change.")
    return 1


def show_org():
    """Print the organization's settings that matter for project creation."""
    doc = _load() or {}
    for key in ("id", "name", "adminGroupId", "adminsCanCreateProjectsInSubtree", "clusters", "allowedClusters"):
        if key in doc:
            print(f"  {key}: {doc[key]}")
    flag = doc.get("adminsCanCreateProjectsInSubtree")
    if flag is False:
        print(f"  {RED}x{RESET} adminsCanCreateProjectsInSubtree is false — creation will be refused")
        return 1
    unknown = [k for k in doc if k not in {"id", "name", "adminGroupId", "adminsCanCreateProjectsInSubtree", "clusters", "allowedClusters"}]
    if unknown:
        print(f"  (other fields: {', '.join(sorted(unknown))})")
    return 0


def find_project(url_name):
    """Confirm a project is listed in the organization."""
    doc = _load() or {}
    items = doc.get("items", doc if isinstance(doc, list) else [])
    for p in items:
        if p.get("urlName") == url_name or p.get("name") == url_name:
            print(f"  {GREEN}v{RESET} '{url_name}' is listed (cluster {p.get('cluster', '?')})")
            return 0
    listed = [p.get("urlName") or p.get("name") for p in items]
    print(f"  {RED}x{RESET} '{url_name}' not listed. Projects: {listed or 'none'}")
    return 1


def error_text():
    """Print just the error message from a failed response."""
    print(error_message(_load()))
    return 0


def token_issuer():
    """Print the `iss` claim of a raw JWT read from stdin. Used to find the auth server."""
    import base64

    raw = sys.stdin.read().strip()
    try:
        payload = raw.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        print(json.loads(base64.urlsafe_b64decode(payload)).get("iss", ""))
    except (IndexError, ValueError):
        print("")
    return 0


COMMANDS = {
    "token-issuer": token_issuer,
    "show-org": show_org,
    "find-project": find_project,
    "error-text": error_text,
    "show-claims": show_claims,
    "show-access": show_access,
    "list-groups": list_groups,
    "check-access": check_access,
    "find-group": find_group,
    "build-body": build_body,
    "created-id": created_id,
    "show-group": show_group,
}

if __name__ == "__main__":
    command, *args = sys.argv[1:]
    sys.exit(COMMANDS[command](*args))
