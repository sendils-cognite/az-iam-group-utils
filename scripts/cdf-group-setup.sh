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

info "Target"
echo "  project    $PROJECT ($CLUSTER)"
echo "  CDF group  $GROUP_NAME"
echo "  sourceId   $SOURCE_ID"
echo "  client id  $CLIENT_ID"

# --- get an admin token as the signed-in user --------------------------------
info "Authenticating as you"
az account show >/dev/null 2>&1 || die "not signed in — run: az login --allow-no-subscriptions"

TOKEN_ERR="$(az account get-access-token --scope "$BASE/.default" --query accessToken -o tsv 2>&1 >/dev/null)"
TOKEN="$(az account get-access-token --scope "$BASE/.default" --query accessToken -o tsv 2>/dev/null)"

if [[ -z "$TOKEN" ]]; then
  TENANT="$(az account show --query tenantId -o tsv 2>/dev/null)"
  if grep -q 'AADSTS65001' <<<"$TOKEN_ERR"; then
    # First use of the Azure CLI app against this CDF cluster in this tenant.
    die "the Azure CLI app is not yet consented for $BASE in your tenant.
       This is a one-time step. Run:

         az login --tenant \"$TENANT\" --scope \"$BASE/.default\" --allow-no-subscriptions

       Approve the consent prompt in the browser, then re-run this script.
       If the prompt says an admin must approve, ask a tenant admin to run it."
  fi
  die "could not get a CDF token from your az session:
       ${TOKEN_ERR:0:300}"
fi
ok "got a CDF token for $BASE"

api() { # method url [body]
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "$body" "$url"
  else
    curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" "$url"
  fi
}

# --- confirm you may actually create groups here -----------------------------
api GET "$API/token/inspect" | python3 "$HELPER" check-access "$PROJECT" \
  || die "cannot create groups in '$PROJECT' as your user — ask a CDF admin to run this, or to grant groupsAcl:CREATE"
ok "you have groupsAcl:CREATE in $PROJECT"

# --- idempotency: is there already a group for this Entra group? -------------
MATCH="$(api GET "$API/groups" | python3 "$HELPER" find-group "$SOURCE_ID" "$GROUP_NAME")"
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
GID="$(api POST "$API/groups" "$BODY" | python3 "$HELPER" created-id)" \
  || die "CDF rejected the group — see the message above"
ok "created CDF group '$GROUP_NAME' (id $GID)"

# --- verify it is really there and linked ------------------------------------
info "Verifying"
api GET "$API/groups" | python3 "$HELPER" show-group "$GID" "$SOURCE_ID" || die "verification failed"

info "Done"
cat <<EOF
The service principal now has access to '$PROJECT'.

Group membership is resolved when a token is issued, so a token minted in the last few
minutes may not show the new access yet. Confirm with:

  cd .cdf-auth && ./verify.sh --token

Capabilities came from $CAPS_FILE — edit it and re-run to change them.
EOF
