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


COMMANDS = {
    "check-access": check_access,
    "find-group": find_group,
    "build-body": build_body,
    "created-id": created_id,
    "show-group": show_group,
}

if __name__ == "__main__":
    command, *args = sys.argv[1:]
    sys.exit(COMMANDS[command](*args))
