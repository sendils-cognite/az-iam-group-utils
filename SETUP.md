# Setup guide (macOS, from a clean machine)

For someone with **nothing installed**. Follow top to bottom; every command is meant to be
pasted into Terminal. Expect 15–20 minutes, most of it downloads.

At the end you will have a `.env` at the root of your project containing the Entra ID
credentials your CDF code needs.

---

## Before you start

You need three things that this tool cannot create for you:

| What | How to get it |
|---|---|
| An Azure account that can create groups and app registrations in your Entra ID tenant | Ask your Azure admin for **Application Developer** + **Groups Administrator**, or **Cloud Application Administrator**. Without this you get `403 Authorization_RequestDenied`. |
| Your **CDF cluster** | The host in your Fusion URL — in `https://bluefield.fusion.cognite.com/my-project`, the cluster is `bluefield`. |
| Your **CDF project** name | The path segment — in the URL above, `my-project`. |
| Access to this repository | It is private. Ask the owner to add you. |

Get the cluster and project right. Both are accepted silently if wrong, and only fail later
when your code tries to authenticate or call the API.

---

## Step 1 — Open Terminal

Press `Cmd + Space`, type `Terminal`, press Enter.

Check which Mac you have — the install paths differ:

```bash
uname -m
```

`arm64` means Apple Silicon (M1/M2/M3/M4), `x86_64` means Intel. Note which one; Step 2 needs it.

---

## Step 2 — Install Homebrew

Homebrew is the package manager everything else installs through.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

It will ask for your Mac login password (nothing is shown as you type — that is normal) and may
install Apple's Command Line Tools first, which takes several minutes.

**Apple Silicon only** — Homebrew is not on your `PATH` yet. Run both lines:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Confirm:

```bash
brew --version
```

If that says `command not found`, close Terminal, open it again, and retry.

---

## Step 3 — Install Terraform, Azure CLI and Git

**Terraform is not in Homebrew's main catalogue.** HashiCorp moved it to their own tap after a
licence change, so plain `brew install terraform` fails. Use the tap:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

Then the Azure CLI and Git:

```bash
brew install azure-cli git
```

Verify all three — each should print a version:

```bash
terraform version
az version
git --version
```

---

## Step 4 — Get the code

```bash
git clone https://github.com/sendils-cognite/az-iam-group-utils.git
cd az-iam-group-utils
```

The repo is **private**, so Git will ask who you are. The simplest route is GitHub's CLI:

```bash
brew install gh
gh auth login
```

Choose `GitHub.com` → `HTTPS` → `Login with a web browser`, follow the prompts, then retry the
`git clone`.

---

## Step 5 — Sign in to Azure

```bash
az login --allow-no-subscriptions
```

A browser window opens; sign in there.

`--allow-no-subscriptions` matters. Entra ID groups and app registrations live at the *tenant*
level, not under a subscription, and `az login` otherwise refuses when your account has no
subscription in that tenant.

Now find your tenant ID:

```bash
az account show --query tenantId -o tsv
```

**Use that value.** Do not use `az account list` — it lists *subscriptions*, which frequently sit
in a different tenant from the one you can create objects in. Picking the wrong one is the most
common cause of the `403` in Troubleshooting below.

If you belong to several tenants and the active one is wrong:

```bash
az login --tenant <the-tenant-id-you-want> --allow-no-subscriptions
```

---

## Step 6 — Run it

Go to the project that needs the credentials — the `.env` is written at *its* root, not here:

```bash
cd ~/path/to/my-project
```

Then run the script, substituting your four values:

```bash
~/az-iam-group-utils/scripts/cdf-auth-setup.sh \
  --tenant <tenant-id> \
  --cluster <cluster> \
  --cdf-project <project> \
  --prefix myteam
```

- `--prefix` names the objects `<prefix>-admin` and `<prefix>-app`. It defaults to `cdf`, but in a
  shared tenant pick something specific to you — the run fails if those names already exist.
- Add `--plan-only` first if you want to see what would be created without creating it.

The script creates the Entra objects, writes the `.env`, and verifies the result. Expect
`20 passed, 0 failed`.

It also adds `.env` and `.cdf-auth/` to your project's `.gitignore`, so the credentials are not
committed.

---

## Step 7 — Finish in CDF

Azure now has the identity, but CDF does not yet trust it. The script prints an Entra group ID:

```
Entra group id    bd3c8c1b-9916-4659-b83c-c0378bfbee59
```

In CDF, create a group whose **Source ID** is that value, and give it the capabilities you need.
**Nothing works until you do this** — you will get a token, but every API call returns 401.

To check the credentials themselves work:

```bash
cd .cdf-auth && ./verify.sh --token
```

---

## What you end up with

```
my-project/
├── .env          # your credentials, readable only by you (mode 0600)
├── .cdf-auth/    # Terraform state — also contains the secret
└── .gitignore    # both entries added automatically
```

`.env` contains:

```
IDP_TENANT_ID=…
IDP_CLIENT_ID=…
IDP_CLIENT_SECRET=…
IDP_TOKEN_URL=…
IDP_SCOPES=…
CDF_CLUSTER=…
CDF_PROJECT=…
CDF_URL=…
ENTRA_GROUP_ID=…
```

The names match what the Cognite Toolkit and SDK expect, so it drops straight in.

**Both `.env` and `.cdf-auth/terraform.tfstate` hold the client secret in plaintext.** Never
commit them, never paste them into chat or a ticket. To share access, have the other person run
this tool themselves.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `zsh: command not found: brew` | Homebrew is not on `PATH`. Re-run the two `~/.zprofile` lines in Step 2, then open a new Terminal. |
| `Error: No available formula with the name "terraform"` | You skipped the tap. Use `brew install hashicorp/tap/terraform` (Step 3). |
| `Please run 'az login' to setup account` | Not signed in, or the session expired. Re-run Step 5. |
| `No subscriptions found` during login | You omitted `--allow-no-subscriptions`. |
| `403 Authorization_RequestDenied` | Either your account lacks rights in this tenant, or you are signed in to the *wrong* tenant. Check with `az account show --query tenantId -o tsv` and compare to your `--tenant`. The script catches the mismatch before calling Azure. |
| `An existing "azuread_application" with name … was found` | Those names are taken in this tenant. Re-run with a different `--prefix`. This guard is deliberate — it stops two identically named app registrations appearing. |
| `AADSTS500011` when requesting a token | Wrong `--cluster`. The CDF cluster has no app registered in your tenant under that name. Check the host in your Fusion URL. |
| `.env already exists and is not managed by this tool` | You already have an `.env` there. Back it up, then re-run with `--force`. |
| `Repository not found` on `git clone` | The repo is private and you lack access, or `gh` is signed in as the wrong account. Check with `gh auth status`. |
| 404 on CDF API calls after setup | `CDF_PROJECT` is wrong, or you skipped Step 7. |

---

## Changing or removing it

Re-run the same command with different values to update the `.env` — the credentials are not
rotated and nothing is duplicated.

To rotate the secret:

```bash
terraform -chdir=.cdf-auth apply -replace=azuread_application_password.cdf
```

To delete everything — the group, app registration, service principal and `.env`:

```bash
terraform -chdir=.cdf-auth destroy
```

This revokes credentials that other people or pipelines may be using. Check before you run it.
