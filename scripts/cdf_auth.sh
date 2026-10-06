# Sourced by the cdf-* scripts. Resolves an access token into TOKEN/TOKEN_SOURCE.
#
# Order: --token-file, CDF_TOKEN, an admin service principal, the principal in .env,
# then the az session. Callers set TOKEN_FILE, ENV_FILE and AUDIENCE first.
#
# AUDIENCE is the resource the token must be for:
#   a CDF cluster (https://<cluster>.cognitedata.com) for project-scoped APIs
#   https://auth.cognite.com for organization APIs
#
# Never echoes a secret.

resolve_token() {
  TOKEN="" TOKEN_SOURCE=""

  if [[ -n "${TOKEN_FILE:-}" ]]; then
    [[ -f "$TOKEN_FILE" ]] || die "token file not found: $TOKEN_FILE"
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    [[ -n "$TOKEN" ]] || die "token file is empty: $TOKEN_FILE"
    TOKEN_SOURCE="token file $TOKEN_FILE"
    return 0
  fi

  if [[ -n "${CDF_TOKEN:-}" ]]; then
    TOKEN="$CDF_TOKEN"
    TOKEN_SOURCE="CDF_TOKEN environment variable"
    return 0
  fi

  local token_url scopes
  token_url="$(get IDP_TOKEN_URL)"
  scopes="${AUDIENCE:-$(get IDP_SCOPES)}/.default"
  [[ "$scopes" == */.default/.default ]] && scopes="${scopes%/.default}"

  if [[ -n "${CDF_ADMIN_CLIENT_ID:-}" && -n "${CDF_ADMIN_CLIENT_SECRET:-}" ]]; then
    TOKEN="$(_client_credentials "$token_url" "$CDF_ADMIN_CLIENT_ID" "$CDF_ADMIN_CLIENT_SECRET" "$scopes")"
    [[ -n "$TOKEN" ]] || die "client_credentials grant failed for CDF_ADMIN_CLIENT_ID"
    TOKEN_SOURCE="admin service principal $CDF_ADMIN_CLIENT_ID"
    return 0
  fi

  local self_id self_secret
  self_id="$(get IDP_CLIENT_ID)"
  self_secret="$(get IDP_CLIENT_SECRET)"
  if [[ -n "$self_id" && -n "$self_secret" && -n "$token_url" ]]; then
    TOKEN="$(_client_credentials "$token_url" "$self_id" "$self_secret" "$scopes")"
    if [[ -n "$TOKEN" ]]; then
      TOKEN_SOURCE="the service principal in .env ($self_id)"
      return 0
    fi
  fi

  if command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then
    TOKEN="$(az account get-access-token --scope "$scopes" --query accessToken -o tsv 2>/dev/null)"
    if [[ -n "$TOKEN" ]]; then
      TOKEN_SOURCE="your az login session"
      return 0
    fi
  fi

  return 1
}

_client_credentials() { # token_url client_id client_secret scopes
  curl -sS -X POST "$1" \
    -d grant_type=client_credentials -d "client_id=$2" \
    -d "client_secret=$3" -d "scope=$4" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null
}
