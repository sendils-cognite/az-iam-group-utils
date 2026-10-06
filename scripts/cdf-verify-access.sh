#!/usr/bin/env bash
# End-to-end check that the service principal can actually reach CDF.
#
#   cdf-verify-access.sh [--root DIR]
#
# Two steps, both of which must pass:
#   1. the client credentials in .env can obtain a token from Entra ID
#   2. CDF accepts that token and reports access to the project
#
# Step 2 is what proves the CDF group exists and is linked to the Entra group — a token
# issues happily even when the principal has no CDF access at all.
#
# The client secret is read from .env, used once, and never printed.

set -uo pipefail

ROOT="" SHOW_CLAIMS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --claims) SHOW_CLAIMS=1; shift ;;
    *) printf '\033[31merror:\033[0m unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

die()  { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }

[[ -n "$ROOT" ]] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$(cd "$ROOT" && pwd)/.env"
[[ -f "$ENV_FILE" ]] || die "no .env at $ROOT"

set -a; . "$ENV_FILE"; set +a
for v in IDP_TOKEN_URL IDP_CLIENT_ID IDP_CLIENT_SECRET IDP_SCOPES CDF_URL CDF_PROJECT ENTRA_GROUP_ID; do
  [[ -n "${!v:-}" ]] || die "$v missing from $ENV_FILE"
done

echo "Project $CDF_PROJECT at $CDF_URL"
echo

# --- 1. can we get a token at all? -------------------------------------------
RESP="$(curl -sS -X POST "$IDP_TOKEN_URL" \
  -d grant_type=client_credentials \
  -d "client_id=$IDP_CLIENT_ID" \
  -d "client_secret=$IDP_CLIENT_SECRET" \
  -d "scope=$IDP_SCOPES")" || die "could not reach $IDP_TOKEN_URL"

TOKEN="$(python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' <<<"$RESP" 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  ERR="$(python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("error",""),"-",d.get("error_description","")[:160])' <<<"$RESP" 2>/dev/null)"
  case "$ERR" in
    *AADSTS500011*) die "no token: $ERR
   The CDF cluster in IDP_SCOPES has no app registered in this tenant — check CDF_CLUSTER." ;;
    *AADSTS7000215*) die "no token: $ERR
   The client secret is wrong or expired. Re-run terraform apply -replace=azuread_application_password.cdf" ;;
    *) die "no token: ${ERR:-unparseable response}" ;;
  esac
fi
ok "Entra ID issued a token for $IDP_SCOPES"

if [[ "$SHOW_CLAIMS" -eq 1 ]]; then
  echo
  echo "Token claims:"
  python3 "$(dirname "${BASH_SOURCE[0]}")/cdf_helpers.py" show-claims <<<"$RESP"
  echo
fi

# --- 2. does CDF grant it anything? ------------------------------------------
OUT="$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$CDF_URL/api/v1/token/inspect")" \
  || die "could not reach $CDF_URL"
STATUS="${OUT##*$'\n'}"
BODY="${OUT%$'\n'*}"

if [[ "$STATUS" != "200" ]]; then
  die "CDF rejected the token (HTTP $STATUS). A 401 here with a valid token usually means no CDF
   group has sourceId $ENTRA_GROUP_ID yet."
fi
ok "CDF accepted the token"

python3 "$(dirname "${BASH_SOURCE[0]}")/cdf_helpers.py" show-access "$CDF_PROJECT" <<<"$BODY"
RC=$?

echo
[[ $RC -eq 0 ]] && echo "Setup works end to end." || echo "Setup is incomplete — see above."
exit $RC
