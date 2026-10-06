#!/usr/bin/env bash
# Creates a CDF project in an organization, with an Entra group as its admin group.
#
#   cdf-project-setup.sh --org ORG --url-name NAME --cluster CLUSTER
#                        [--name "Display Name"] [--admin-group-id ID]
#                        [--root DIR] [--token-file FILE] [--auth-base URL] [--dry-run]
#
# Why this avoids the bootstrapping problem that cdf-group-setup.sh has: a project is
# created with projectAdminGroupId set to an IdP group. Point that at the Entra group
# this tool already made, and the service principal in it is an admin of the project
# from the moment it exists — no CDF group to create afterwards.
#
# Organization APIs live on auth.cognite.com, not on a cluster host, and need a token
# for that audience. A token copied from Fusion is the reliable source; a cluster-scoped
# service-principal token will NOT be accepted.

set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$MODULE_DIR/scripts/cdf_helpers.py"
AUTH_BASE="https://auth.cognite.com"

ORG="" URL_NAME="" CLUSTER="" DISPLAY_NAME="" ADMIN_GROUP_ID="" AUTH_BASE_OVERRIDE=""
ROOT="" TOKEN_FILE="" DRY_RUN=0

die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)            ORG="${2:-}"; shift 2 ;;
    --url-name)       URL_NAME="${2:-}"; shift 2 ;;
    --cluster)        CLUSTER="${2:-}"; shift 2 ;;
    --name)           DISPLAY_NAME="${2:-}"; shift 2 ;;
    --admin-group-id) ADMIN_GROUP_ID="${2:-}"; shift 2 ;;
    --root)           ROOT="${2:-}"; shift 2 ;;
    --token-file)     TOKEN_FILE="${2:-}"; shift 2 ;;
    --auth-base)      AUTH_BASE_OVERRIDE="${2:-}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v curl >/dev/null 2>&1    || die "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
[[ -n "$ORG" ]]      || die "--org is required (the name in your Fusion URL, e.g. cog-staging-sendil-sandbox)"
[[ -n "$URL_NAME" ]] || die "--url-name is required (3-32 chars, letters/digits/hyphens, used in URLs)"
[[ -n "$CLUSTER" ]]  || die "--cluster is required and cannot be changed later"
[[ "$URL_NAME" =~ ^[A-Za-z0-9-]{3,32}$ ]] || die "--url-name must be 3-32 chars: letters, digits, hyphens"
[[ "$URL_NAME" =~ [A-Za-z] ]] || die "--url-name must contain at least one letter"
[[ "$URL_NAME" != -* && "$URL_NAME" != *- ]] || die "--url-name may not start or end with a hyphen"
[[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$URL_NAME"

# --- the admin group comes from .env unless overridden ------------------------
[[ -n "$ROOT" ]] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$(cd "$ROOT" && pwd)/.env"
get() { [[ -f "$ENV_FILE" ]] && grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true; }

[[ -n "$ADMIN_GROUP_ID" ]] || ADMIN_GROUP_ID="$(get ENTRA_GROUP_ID)"
[[ -n "$ADMIN_GROUP_ID" ]] || die "no admin group: pass --admin-group-id, or run cdf-auth-setup.sh first so .env has ENTRA_GROUP_ID"

info "Plan"
echo "  organization  $ORG"
echo "  project       $URL_NAME  ($DISPLAY_NAME)"
echo "  cluster       $CLUSTER   (permanent — a project cannot be moved)"
echo "  admin group   $ADMIN_GROUP_ID  (Entra group id)"

# --- token for the auth.cognite.com audience ---------------------------------
info "Authenticating"
AUDIENCE="$AUTH_BASE"
# shellcheck source=/dev/null
. "$MODULE_DIR/scripts/cdf_auth.sh"
resolve_token || die "no usable token for $AUTH_BASE.

       Organization APIs need a token from your organization's authorization server; a
       cluster-scoped service principal token will not work. Copy one from Fusion:
         sign in at https://$ORG.fusion.cognite.com, open DevTools, Network tab, pick a
         request to the auth host and copy the value after 'Bearer '. Then:
           (umask 077; pbpaste > ~/.cdf-token)
           $0 $* --token-file ~/.cdf-token"
ok "token via $TOKEN_SOURCE"

# Staging and other deployments use their own authorization server, so trust the
# token's issuer over the production default.
if [[ -n "$AUTH_BASE_OVERRIDE" ]]; then
  AUTH_BASE="$AUTH_BASE_OVERRIDE"
  ok "auth server $AUTH_BASE (from --auth-base)"
else
  ISSUER="$(python3 "$HELPER" token-issuer <<<"$TOKEN")"
  if [[ -n "$ISSUER" && "$ISSUER" != "$AUTH_BASE" ]]; then
    AUTH_BASE="${ISSUER%/}"
    ok "auth server $AUTH_BASE (from the token's iss claim)"
  else
    ok "auth server $AUTH_BASE"
  fi
fi

RESP="" HTTP_STATUS=""
call() { # method url [body]
  local method="$1" url="$2" body="${3:-}" out
  if [[ -n "$body" ]]; then
    out="$(curl -sS -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "$body" "$url")" || { HTTP_STATUS=000; RESP=""; return 1; }
  else
    out="$(curl -sS -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN" "$url")" \
      || { HTTP_STATUS=000; RESP=""; return 1; }
  fi
  HTTP_STATUS="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}

# --- what does the org allow? ------------------------------------------------
info "Reading organization $ORG"
call GET "$AUTH_BASE/api/v1/orgs/$ORG"
case "$HTTP_STATUS" in
  200) ;;
  401) die "token rejected by $AUTH_BASE (401) — expired, or not issued by that server.
       Organization APIs need a token from your org's authorization server, not a
       cluster-scoped service-principal token. Copy a fresh one from Fusion." ;;
  403) die "not an admin of organization '$ORG' (403). Project creation requires org admin." ;;
  404) die "organization '$ORG' not found. Use the name from your Fusion URL." ;;
  *)   die "unexpected HTTP $HTTP_STATUS reading the organization" ;;
esac
python3 "$HELPER" show-org <<<"$RESP"

# --- create ------------------------------------------------------------------
# Verified against the live API: an items envelope, `name` is the URL name (there is no
# separate urlName), and the cluster field is `clusterName`.
BODY="$(python3 -c '
import json, sys
name, url_name, cluster, admin_group = sys.argv[1:5]
print(json.dumps({"items": [{"name": url_name, "clusterName": cluster, "projectAdminGroupId": admin_group}]}))
' "$DISPLAY_NAME" "$URL_NAME" "$CLUSTER" "$ADMIN_GROUP_ID")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "Dry run — would POST to $AUTH_BASE/api/v1/orgs/$ORG/projects"
  python3 -m json.tool <<<"$BODY"
  exit 0
fi

info "Creating the project"
call POST "$AUTH_BASE/api/v1/orgs/$ORG/projects" "$BODY"
case "$HTTP_STATUS" in
  200|201) ok "project '$URL_NAME' created on $CLUSTER" ;;
  403) die "refused (403). Either you are not an org admin, or adminsCanCreateProjectsInSubtree
       is false for '$ORG'. Both are set by an organization admin." ;;
  409) die "a project named '$URL_NAME' already exists in '$ORG'." ;;
  400) die "rejected (400): $(python3 "$HELPER" error-text <<<"$RESP")
       A bad cluster is the usual cause — it must be one the organization allows." ;;
  *)   die "unexpected HTTP $HTTP_STATUS: $(python3 "$HELPER" error-text <<<"$RESP")" ;;
esac

# --- verify ------------------------------------------------------------------
info "Verifying"
call GET "$AUTH_BASE/api/v1/orgs/$ORG/projects"
python3 "$HELPER" find-project "$URL_NAME" <<<"$RESP" || die "project not listed after creation"

cat <<EOF

$(info "Done")
  Fusion        https://$ORG.fusion.cognite.com/$URL_NAME
  API           https://$CLUSTER.cognitedata.com
  admin group   $ADMIN_GROUP_ID

Members of that Entra group — including the service principal in your .env — are admins of
the project already. There is no CDF group to create.

Point your .env at it by re-running cdf-auth-setup.sh with
  --cdf-project $URL_NAME --cluster $CLUSTER
then check access with:
  scripts/cdf-verify-access.sh --root $ROOT
EOF
