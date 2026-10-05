---
name: cdf-auth-setup
description: Set up Entra ID (Azure AD) authentication for a CDF project — creates a security group, app registration and client secret, then writes a ready-to-use .env into the current project root. Use when the user wants CDF credentials, service-principal auth, an .env for Cognite Toolkit/SDK, or mentions setting up Azure app registration for CDF.
---

# Set up CDF authentication from Entra ID

Creates three things in Entra ID — a security group, an app registration (with its service
principal added to that group), and a client secret — then writes a `.env` at the root of the
project the conversation is happening in.

The heavy lifting is done by `scripts/cdf-auth-setup.sh`. Your job is to gather four inputs,
confirm them, run the script once, and report the result. Do not hand-roll `az ad` commands.

## Step 1 — check the Azure session

```bash
az account show --query "{tenant:tenantId,user:user.name}" -o json
```

If this fails, the user is not logged in. Tell them to run `az login --tenant <id> --allow-no-subscriptions`
and stop — do not attempt to log in for them, it needs a browser.

**The active tenant matters.** `az account list` shows *subscriptions*, which often all live in a
different tenant from the one the user can create directory objects in. Trust
`az account show --query tenantId` for the active tenant, and offer the others only as alternatives:

```bash
az account list --all --query "[].{tenant:tenantId,name:name}" -o table
```

Creating objects in a tenant where the user lacks rights fails with
`403 Authorization_RequestDenied`. The user needs to be able to create groups and app registrations
there (Application Developer + Groups Administrator, or Cloud Application Administrator, or Global
Administrator). To check their roles in the active tenant:

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/me/memberOf" --query "value[].displayName" -o json
```

## Step 2 — gather the inputs

Use the AskUserQuestion tool. Prefill what you can discover; never invent values.

| Input | Notes |
|---|---|
| `--tenant` | GUID. Default to the active `az` tenant. |
| `--cluster` | CDF cluster, e.g. `bluefield`, `westeurope-1`, `api`, `az-eastus-1`. **Must be right** — it builds `IDP_SCOPES`, and a wrong value makes token requests fail with `AADSTS500011`. It is the host in the user's Fusion URL. |
| `--cdf-project` | CDF project name — the path segment in `https://<cluster>.fusion.cognite.com/<project>`. Ask; it is not discoverable from Azure. |
| `--prefix` | Optional, defaults to `cdf`. Names the objects `<prefix>-admin` and `<prefix>-app`. Suggest something project-specific if the tenant is shared. |

Do not guess the cluster or the CDF project. Both are silent failures if wrong: the objects get
created successfully and only break later, at token or API time.

## Step 3 — run it

```bash
scripts/cdf-auth-setup.sh --tenant <guid> --cluster <cluster> --cdf-project <name> [--prefix <p>]
```

The script resolves the target folder itself: the git repo root of the current directory, else the
current directory. Pass `--root <dir>` only if the user wants it somewhere specific.

Useful flags:

- `--plan-only` — show what Terraform would create, without creating it. Good when the user is unsure.
- `--force` — overwrite a pre-existing unmanaged `.env`. The script refuses without it, by design.
- `--days N` — client secret lifetime, default 180.

The script is idempotent: state lives in `<root>/.cdf-auth/`, so re-running with the same inputs
changes nothing, and re-running with a new cluster or project just re-renders the `.env` without
rotating the secret.

Because state is per-project, it cannot see objects a *different* project created. The module sets
`prevent_duplicate_names = true`, so if `<prefix>-admin` or `<prefix>-app` already exists in the
tenant, the apply fails with `existing group/application was found with the display name`. That is
deliberate — it stops a second set of identically named objects appearing. When it happens, ask the
user whether to:

- pick a project-specific `--prefix` (usually right), or
- reuse the existing objects, which this tool does not manage — they would import them with
  `terraform -chdir=.cdf-auth import` or get the credentials from whoever created them.

## Step 3b — grant access in CDF

The Azure identity alone grants nothing. Immediately after a successful run, offer to create the
matching CDF group:

```bash
scripts/cdf-group-setup.sh
```

It reads `CDF_CLUSTER`, `CDF_PROJECT` and `ENTRA_GROUP_ID` from the generated `.env` — never the
secret — and creates a CDF group linked to the Entra group, with the capabilities in
`cdf-capabilities.json` (`groupsAcl` full, `projectsAcl` LIST/READ, `datasetsAcl` READ/WRITE).
Pass `--dry-run` to show the payload first, `--group-name` to override the default
`<project>-admin`, `--capabilities <file>` for a different set.

It runs as the signed-in user, because a brand-new service principal has no `groupsAcl:CREATE`
and cannot create its own group. The user must be a CDF admin in that project.

Two failures to expect and how to respond:

- **`AADSTS65001`** on the first run in a tenant — the Azure CLI app is not consented for the CDF
  cluster. The script prints the exact `az login --scope …` command; relay it verbatim and have
  the user run it, then re-run. Do not run `az login` for them; it needs a browser.
- **`AADSTS650057`** — the CDF application in that tenant does not list the Azure CLI as a
  permitted client. Consent cannot fix this; stop suggesting `az login`. Offer instead
  `CDF_TOKEN=<token>` (from Fusion DevTools) or
  `CDF_ADMIN_CLIENT_ID`/`CDF_ADMIN_CLIENT_SECRET` for an existing admin service principal.
- **no `groupsAcl:CREATE`** — the user is not a CDF admin there. They need an admin to run the
  script or grant the capability. Do not try to work around it.

The script is idempotent: if a CDF group already points at that Entra group it exits cleanly. If a
group of the same *name* exists with a different `sourceId` it stops and asks for `--group-name`.

## Step 4 — report

The script prints the client ID, group object ID, `.env` path, and runs verification against
Microsoft Graph. Relay:

1. What was created, and that `.env` is at the project root with mode `0600`.
2. Whether the CDF group was created (Step 3b). If it was not — because of the consent error or
   missing admin rights — say so plainly: the credentials exist but grant no access yet, and every
   CDF API call will return 401 until a group with that `sourceId` exists.
3. That `.cdf-auth/terraform.tfstate` contains the secret in plaintext. Both it and `.env` are
   added to `.gitignore` automatically — confirm that happened.

If verification reports failures, read them out and fix the cause; do not describe a partial setup
as complete.

## Secret handling

Never print the client secret, never `cat` the `.env`, and never paste the secret into a command
you construct. To prove the credentials work, tell the user to run the token check themselves:

```bash
cd .cdf-auth && ./verify.sh --token
```

## Teardown

```bash
terraform -chdir=.cdf-auth destroy
```

Deletes the group, app registration, service principal, and the `.env`. Confirm with the user
before running it — it revokes credentials that other things may be using.
