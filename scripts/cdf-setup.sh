#!/usr/bin/env bash
# Interactive front end for the whole setup. Asks for what it needs instead of
# requiring flags, so nothing has to be typed into a command line.
#
#   ./scripts/cdf-setup.sh
#
# Run it in a real terminal — it reads from the keyboard. Every underlying script
# is still usable directly with flags for scripted or repeat runs.

set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$MODULE_DIR/scripts"

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'

die()   { printf '%serror:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }
ok()    { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$1"; }
title() { printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }
note()  { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }

# Prefer the terminal so the wizard still works when stdout is piped to a pager.
if ( : < /dev/tty ) 2>/dev/null; then exec 3< /dev/tty; else exec 3<&0; fi

# ask VAR "Question" [default] [regex] [message] — re-asks until valid.
ask() {
  local __var="$1" prompt="$2" default="${3:-}" pattern="${4:-}" message="${5:-}" reply
  while true; do
    if [[ -n "$default" ]]; then
      printf '%s [%s]: ' "$prompt" "$default"
    else
      printf '%s: ' "$prompt"
    fi
    IFS= read -r reply <&3 || die "input closed — run this in a terminal"
    reply="${reply:-$default}"
    if [[ -z "$reply" ]]; then
      printf '  (required)\n'
      continue
    fi
    if [[ -n "$pattern" && ! "$reply" =~ $pattern ]]; then
      printf '  %s\n' "${message:-invalid value}"
      continue
    fi
    printf -v "$__var" '%s' "$reply"
    return 0
  done
}

# confirm "Question" [Y|N] — default applies to a bare Enter.
confirm() {
  local prompt="$1" default="${2:-Y}" reply hint="[Y/n]"
  [[ "$default" == N ]] && hint="[y/N]"
  while true; do
    printf '%s %s: ' "$prompt" "$hint"
    IFS= read -r reply <&3 || die "input closed — run this in a terminal"
    reply="${reply:-$default}"
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
      *) printf '  please answer y or n\n' ;;
    esac
  done
}

# choose VAR "Question" opt1 opt2 ... — numbered menu.
choose() {
  local __var="$1" prompt="$2"; shift 2
  local options=("$@") i reply
  printf '%s\n' "$prompt"
  for i in "${!options[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${options[$i]}"; done
  while true; do
    printf 'Choice [1]: '
    IFS= read -r reply <&3 || die "input closed — run this in a terminal"
    reply="${reply:-1}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#options[@]} )); then
      printf -v "$__var" '%s' "${options[$((reply - 1))]}"
      return 0
    fi
    printf '  pick a number between 1 and %d\n' "${#options[@]}"
  done
}

# Reads a secret into a file without echoing it or putting it in shell history.
read_token_to_file() {
  local path="$1" token
  printf 'Paste the token (it will not be shown), then press Enter:\n> '
  IFS= read -rs token <&3 || die "input closed"
  printf '\n'
  token="${token#Bearer }"; token="$(tr -d '[:space:]' <<<"$token")"
  [[ -n "$token" ]] || return 1
  [[ "$token" == eyJ* ]] || { warn "that does not look like a token (should start 'eyJ')"; return 1; }
  (umask 077; printf '%s' "$token" > "$path")
  ok "token saved to $path"
}

# ---------------------------------------------------------------------------
printf '%sCDF authentication setup%s\n' "$BOLD" "$OFF"
note "Creates the Entra ID identity for a CDF project and writes a .env."
note "Press Ctrl-C at any point to stop; nothing is created until you confirm."

title "Checking prerequisites"
for tool in terraform az python3 curl; do
  command -v "$tool" >/dev/null 2>&1 && ok "$tool" || die "$tool not found — see SETUP.md"
done

ACTIVE_TENANT="$(az account show --query tenantId -o tsv 2>/dev/null)"
if [[ -z "$ACTIVE_TENANT" ]]; then
  die "not signed in to Azure. Run this first, then start again:
       az login --allow-no-subscriptions"
fi
ok "signed in to Azure tenant $ACTIVE_TENANT"

title "Where should the .env go?"
DEFAULT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ask ROOT "Project folder" "$DEFAULT_ROOT"
ROOT="${ROOT/#\~/$HOME}"
[[ -d "$ROOT" ]] || die "not a directory: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
ok "$ROOT/.env"

title "Entra ID tenant"
ask TENANT "Tenant ID" "$ACTIVE_TENANT" '^[0-9a-fA-F-]{36}$' "a tenant id is a GUID, e.g. ${ACTIVE_TENANT}"
if [[ "$TENANT" != "$ACTIVE_TENANT" ]]; then
  die "your az session is on $ACTIVE_TENANT. Creating objects in a different tenant fails
       with 403. Run: az login --tenant $TENANT --allow-no-subscriptions"
fi

title "CDF project"
choose PROJECT_MODE "Do you have a CDF project already?" \
  "Yes — use an existing project" \
  "No — create a new one for me"

ORG="" CREATE_PROJECT=0
if [[ "$PROJECT_MODE" == No* ]]; then
  CREATE_PROJECT=1
  note "A new project needs your organization name — the first part of your Fusion URL,"
  note "e.g. https://<org>.fusion.cognite.com/<project>"
  ask ORG "Organization" "" '^[A-Za-z0-9-]+$' "letters, digits and hyphens, as it appears in the Fusion URL"
fi

if [[ "$CREATE_PROJECT" -eq 1 ]]; then
  ask CDF_PROJECT "New project name" "" '^[A-Za-z0-9-]{3,32}$' "3-32 characters: letters, digits and hyphens (no underscores for a new project)"
else
  ask CDF_PROJECT "Project name" "" '^[A-Za-z0-9_-]{3,32}$' "3-32 characters: letters, digits, hyphens or underscores"
fi

note "The cluster is the host in your Fusion/API URL: bluefield, greenfield, westeurope-1, api, ..."
[[ "$CREATE_PROJECT" -eq 1 ]] && note "It is permanent — a project cannot be moved later."
ask CLUSTER "Cluster" "" '^[a-z0-9-]+$' "lowercase letters, digits and hyphens, e.g. bluefield"

title "Naming"
note "Objects are named <prefix>-admin (Entra group) and <prefix>-app (app registration)."
ask PREFIX "Prefix" "$CDF_PROJECT" '^[A-Za-z0-9-]+$' "letters, digits and hyphens only"

title "Review"
printf '  tenant      %s\n' "$TENANT"
printf '  project     %s%s\n' "$CDF_PROJECT" "$([[ $CREATE_PROJECT -eq 1 ]] && printf ' (will be created in %s)' "$ORG")"
printf '  cluster     %s\n' "$CLUSTER"
printf '  prefix      %s  ->  %s-admin, %s-app\n' "$PREFIX" "$PREFIX" "$PREFIX"
printf '  .env        %s/.env\n' "$ROOT"
confirm "Proceed?" || { printf 'Stopped. Nothing was created.\n'; exit 0; }

title "Step 1 — Entra ID identity"
"$SCRIPTS/cdf-auth-setup.sh" --tenant "$TENANT" --cluster "$CLUSTER" \
  --cdf-project "$CDF_PROJECT" --prefix "$PREFIX" --root "$ROOT" \
  || die "could not create the Entra ID objects"

GROUP_ID="$(grep -E '^ENTRA_GROUP_ID=' "$ROOT/.env" | cut -d= -f2-)"

if [[ "$CREATE_PROJECT" -eq 1 ]]; then
  title "Step 2 — create the CDF project"
  note "Organization APIs need a token from your org's sign-in, not the service principal."
  note "Open https://$ORG.fusion.cognite.com, press F12, go to Network, click any request,"
  note "and copy the value after 'Bearer ' in its Authorization header."
  TOKEN_PATH="$ROOT/.cdf-auth/org-token"
  mkdir -p "$ROOT/.cdf-auth"
  until read_token_to_file "$TOKEN_PATH"; do
    confirm "Try again?" || die "a token is needed to create a project"
  done

  if confirm "Add yourself to $PREFIX-admin, so you can open the project in a browser too?"; then
    ME="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)"
    if [[ -n "$ME" ]]; then
      az ad group member add --group "$GROUP_ID" --member-id "$ME" >/dev/null 2>&1 \
        && ok "added you to the group" || warn "could not add you (you may already be a member)"
    fi
  fi

  "$SCRIPTS/cdf-project-setup.sh" --org "$ORG" --url-name "$CDF_PROJECT" --cluster "$CLUSTER" \
    --root "$ROOT" --token-file "$TOKEN_PATH" \
    || die "could not create the project"
  rm -f "$TOKEN_PATH"
  note "The project's admin group is the Entra group, so there is no CDF group to create."
else
  title "Step 2 — CDF access"
  note "An existing project needs a CDF group whose Source ID is the Entra group's object id."
  if confirm "Try to create that CDF group now?"; then
    "$SCRIPTS/cdf-group-setup.sh" --root "$ROOT" || {
      warn "could not create it automatically — see the options printed above"
      note "You can also create it by hand in Fusion:"
      note "  Admin -> Access management -> Groups -> Create group"
      note "  Members: Externally managed, Source ID: $GROUP_ID"
    }
  else
    note "Create it in Fusion with Source ID: $GROUP_ID"
  fi
fi

title "Step 3 — verify"
if "$SCRIPTS/cdf-verify-access.sh" --root "$ROOT"; then
  printf '\n%sAll done.%s Credentials are in %s/.env\n' "$GREEN" "$OFF" "$ROOT"
else
  printf '\n%sThe identity exists but CDF does not grant it access yet.%s\n' "$YELLOW" "$OFF"
  note "Most often the CDF group is missing, or its Source ID is not $GROUP_ID"
fi
