#!/usr/bin/env bash
# Creates the CDF-side group that gives the service principal access to a CDF project.
#
#   cdf-group-setup.sh [--root <dir>] [--group-name <name>] [--capabilities <file>] [--dry-run]
#
# Run this after cdf-auth-setup.sh. It reads CDF_CLUSTER, CDF_PROJECT and ENTRA_GROUP_ID from
# the project's .env, and never reads the client secret.
#
# Bootstrapping note: a brand-new service principal cannot create its own CDF group — that needs
# groupsAcl:CREATE, which it does not have yet. So this script acts as *you*, using a CDF token
# from your `az login` session. You must already be a CDF admin in the project.

set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$MODULE_DIR/scripts/cdf_helpers.py"
ROOT="" GROUP_NAME="" CAPS_FILE="$MODULE_DIR/cdf-capabilities.json" DRY_RUN=0

die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)         ROOT="${2:-}"; shift 2 ;;
    --group-name)   GROUP_NAME="${2:-}"; shift 2 ;;
    --capabilities) CAPS_FILE="${2:-}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v az >/dev/null 2>&1      || die "az (Azure CLI) not found on PATH"
command -v curl >/dev/null 2>&1    || die "curl not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
[[ -f "$CAPS_FILE" ]] || die "capabilities file not found: $CAPS_FILE"
[[ -f "$HELPER" ]]    || die "helper not found: $HELPER"

# --- read what cdf-auth-setup.sh produced ------------------------------------
[[ -n "$ROOT" ]] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="$(cd "$ROOT" && pwd)"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || die "no .env at $ROOT — run cdf-auth-setup.sh first"

get() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
CLUSTER="$(get CDF_CLUSTER)"
PROJECT="$(get CDF_PROJECT)"
SOURCE_ID="$(get ENTRA_GROUP_ID)"
CLIENT_ID="$(get IDP_CLIENT_ID)"

[[ -n "$CLUSTER"   ]] || die "CDF_CLUSTER missing from $ENV_FILE"
[[ -n "$PROJECT"   ]] || die "CDF_PROJECT missing from $ENV_FILE"
[[ -n "$SOURCE_ID" ]] || die "ENTRA_GROUP_ID missing from $ENV_FILE"
[[ -n "$GROUP_NAME" ]] || GROUP_NAME="$PROJECT-admin"

BASE="https://$CLUSTER.cognitedata.com"
API="$BASE/api/v1/projects/$PROJECT"
# /token/inspect is NOT project-scoped — it reports which projects the token can reach.
INSPECT_URL="$BASE/api/v1/token/inspect"

info "Target"
echo "  project    $PROJECT ($CLUSTER)"
echo "  CDF group  $GROUP_NAME"
echo "  sourceId   $SOURCE_ID"
echo "  client id  $CLIENT_ID"

# --- get an admin token ------------------------------------------------------
# Three sources, in order of preference. Something that already holds groupsAcl:CREATE
# must mint this token; the newly created service principal cannot.
info "Authenticating"

TOKEN=""
TOKEN_SOURCE=""

if [[ -n "${CDF_TOKEN:-}" ]]; then
  TOKEN="$CDF_TOKEN"
  TOKEN_SOURCE="CDF_TOKEN environment variable"

elif [[ -n "${CDF_ADMIN_CLIENT_ID:-}" && -n "${CDF_ADMIN_CLIENT_SECRET:-}" ]]; then
  TOKEN_URL="$(get IDP_TOKEN_URL)"
  SCOPES="$(get IDP_SCOPES)"
  [[ -n "$TOKEN_URL" && -n "$SCOPES" ]] || die "IDP_TOKEN_URL / IDP_SCOPES missing from $ENV_FILE"
  TOKEN="$(curl -sS -X POST "$TOKEN_URL" \
    -d grant_type=client_credentials \
    -d "client_id=$CDF_ADMIN_CLIENT_ID" \
    -d "client_secret=$CDF_ADMIN_CLIENT_SECRET" \
    -d "scope=$SCOPES" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)"
  [[ -n "$TOKEN" ]] || die "client_credentials grant failed for CDF_ADMIN_CLIENT_ID"
  TOKEN_SOURCE="admin service principal $CDF_ADMIN_CLIENT_ID"

else
  az account show >/dev/null 2>&1 || die "not signed in — run: az login --allow-no-subscriptions"
  TOKEN_ERR="$(az account get-access-token --scope "$BASE/.default" --query accessToken -o tsv 2>&1 >/dev/null)"
  TOKEN="$(az account get-access-token --scope "$BASE/.default" --query accessToken -o tsv 2>/dev/null)"
  TOKEN_SOURCE="your az login session"

  if [[ -z "$TOKEN" ]]; then
    TENANT="$(az account show --query tenantId -o tsv 2>/dev/null)"
    HINT=""
    if grep -q 'AADSTS650057' <<<"$TOKEN_ERR"; then
      HINT="The CDF application in this tenant does not permit the Azure CLI as a client,
       so the az CLI can never get a token for $BASE. Use one of the options below."
    elif grep -q 'AADSTS65001' <<<"$TOKEN_ERR"; then
      HINT="The Azure CLI app is not consented for $BASE yet. Try:
         az login --tenant \"$TENANT\" --scope \"$BASE/.default\" --allow-no-subscriptions
       If that fails with AADSTS650057, use one of the options below instead."
    else
      HINT="${TOKEN_ERR:0:200}"
    fi
    die "could not get a CDF token from your az session.
       $HINT

       Option A — borrow a token from Fusion (expires in about an hour):
         Sign in at https://$CLUSTER.fusion.cognite.com/$PROJECT, open the browser
         DevTools Network tab, pick any request to $CLUSTER.cognitedata.com and copy
         the value after 'Bearer ' in its Authorization header. Then:
           CDF_TOKEN=<token> $0 $*

       Option B — use an existing admin service principal that already has
       groupsAcl:CREATE in '$PROJECT':
           CDF_ADMIN_CLIENT_ID=<id> CDF_ADMIN_CLIENT_SECRET=<secret> $0 $*

       Option C — create the group by hand in Fusion:
         Admin -> Access management -> Groups -> Create group,
         Members -> Externally managed, Source ID = $SOURCE_ID"
  fi
fi

ok "got a CDF token via $TOKEN_SOURCE"

# Sets RESP (body) and HTTP_STATUS. Called directly, never in $(...), so the
# assignments land in this shell — CDF returns an empty body on 401, and the
# status code is then the only useful signal.
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

# --- confirm you may actually create groups here -----------------------------
call GET "$INSPECT_URL"
if ! python3 "$HELPER" check-access "$PROJECT" <<<"$RESP"; then
  case "$HTTP_STATUS" in
    401) die "CDF rejected the token from $TOKEN_SOURCE (HTTP 401 — expired or invalid)." ;;
    403) die "the credential from $TOKEN_SOURCE is authenticated but not authorised in '$PROJECT' (HTTP 403)." ;;
    404) die "CDF returned 404 for $INSPECT_URL — is '$CLUSTER' the right cluster?" ;;
    *)   die "the credential from $TOKEN_SOURCE cannot create groups in '$PROJECT' (HTTP ${HTTP_STATUS:-?}).
       It needs groupsAcl:CREATE there. Use a CDF admin credential, or ask an admin to run this." ;;
  esac
fi
ok "you have groupsAcl:CREATE in $PROJECT"

# --- idempotency: is there already a group for this Entra group? -------------
call GET "$API/groups" || die "could not list groups in '$PROJECT'"
MATCH="$(python3 "$HELPER" find-group "$SOURCE_ID" "$GROUP_NAME" <<<"$RESP")"
if [[ -n "$MATCH" ]]; then
  IFS=$'\t' read -r gid gname why <<<"$MATCH"
  if [[ "$why" == "sourceId" ]]; then
    ok "CDF group '$gname' (id $gid) already links to this Entra group — nothing to do"
    exit 0
  fi
  die "a CDF group named '$gname' (id $gid) already exists with a different sourceId.
       Choose another name with --group-name, or delete that group first."
fi

# --- create it ---------------------------------------------------------------
BODY="$(python3 "$HELPER" build-body "$GROUP_NAME" "$SOURCE_ID" "$CAPS_FILE")" || die "could not build request body"

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "Dry run — would POST to $API/groups"
  python3 -m json.tool <<<"$BODY"
  exit 0
fi

info "Creating the CDF group"
call POST "$API/groups" "$BODY"
GID="$(python3 "$HELPER" created-id <<<"$RESP")" \
  || die "CDF rejected the group (HTTP $HTTP_STATUS) — see the message above"
ok "created CDF group '$GROUP_NAME' (id $GID)"

# --- verify it is really there and linked ------------------------------------
info "Verifying"
call GET "$API/groups" || die "could not re-read groups to verify"
python3 "$HELPER" show-group "$GID" "$SOURCE_ID" <<<"$RESP" || die "verification failed"

info "Done"
cat <<EOF
The service principal now has access to '$PROJECT'.

Group membership is resolved when a token is issued, so a token minted in the last few
minutes may not show the new access yet. Confirm with:

  cd .cdf-auth && ./verify.sh --token

Capabilities came from $CAPS_FILE — edit it and re-run to change them.
EOF
