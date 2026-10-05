# Creating a new Entra ID tenant

This utility creates a group, app registration and secret **inside** a tenant. It cannot create
the tenant itself.

That is a platform limitation, not an omission. Terraform's `azuread` provider has no
`azuread_tenant` resource — it only manages objects within a tenant that already exists. Nor is
there an Azure CLI command or Graph API for creating a workforce tenant: whoever creates one
becomes its first Global Administrator, so Microsoft requires an interactive user, and it cannot
be done with a service principal or in CI.

So the tenant is created by hand in the portal, once. Everything after that is automated by
`scripts/cdf-auth-setup.sh`.

> Creating a **B2C** or **External ID (CIAM)** tenant *is* partly automatable —
> `azurerm_aadb2c_directory` and `Microsoft.AzureActiveDirectory/ciamDirectories` respectively.
> Those are customer-identity tenants and are not what CDF service-principal auth uses. This guide
> covers workforce tenants.

---

## Step 0 — Do you actually need a new one?

Most people don't. You need a new tenant only if you want identities isolated from your
organisation's directory — a personal sandbox, a customer demo, or a throwaway test environment.

If you just need *credentials*, you do not need a tenant: run the utility against a tenant you
already belong to. List them:

```bash
az login
az rest --method GET --url "https://graph.microsoft.com/v1.0/me/memberOf" --query "value[].displayName" -o table
az account list --all --query "[].{subscription:name, tenant:tenantId}" -o table
```

Remember that `az account list` shows **subscriptions**, which often sit in a different tenant from
the one you can create objects in. The tenant you are actually signed in to is:

```bash
az account show --query tenantId -o tsv
```

---

## Step 1 — Check you are allowed to create one

Three separate things can block you. Check all three before opening the portal.

**1. Your account must be a paid customer.** Microsoft restricts workforce tenant creation to paid
accounts — free tenants and trial subscriptions cannot create additional tenants. You need a
Pay-As-You-Go or Enterprise Agreement subscription.

**2. Tenant creation must not be switched off** in the directory's user settings:

```bash
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/policies/authorizationPolicy" \
  --query "defaultUserRolePermissions.allowedToCreateTenants"
```

`true` means ordinary users may create tenants. If it returns `false`, you need the
**Tenant Creator** role assigned by an administrator.

**3. You need to be signed in as a user**, not a service principal. There is no way around this.

---

## Step 2 — Create the tenant

In the portal — this part cannot be scripted:

1. Sign in to <https://portal.azure.com>
2. Select **Microsoft Entra ID**
3. Go to **Entra ID → Overview → Manage tenants**
4. Select **Create**
5. On the **Basics** tab choose **Microsoft Entra ID** (not *Microsoft Entra ID (B2C)*)
   - If that option is greyed out, you have hit one of the three blockers in Step 1.
6. Select **Next: Configuration** and fill in:

   | Field | Notes |
   |---|---|
   | **Organization name** | Display name, e.g. `Contoso Sandbox`. Changeable later. |
   | **Initial domain name** | Becomes `<name>.onmicrosoft.com`. **Permanent** — you can add custom domains later, but this one never goes away. Pick something you can live with. |
   | **Country or region** | Sets the tenant's **data residency**. Treat as permanent — changing it later means creating a new tenant. |

7. **Next: Review + Create**, check the values, then **Create**.

You are automatically assigned **Global Administrator** in the new tenant.

---

## Step 3 — Find the new tenant ID

The portal shows it on the tenant overview page. From the CLI, sign in to the new tenant:

```bash
az login --tenant <new-domain>.onmicrosoft.com --allow-no-subscriptions
az account show --query tenantId -o tsv
```

`--allow-no-subscriptions` is required. A brand-new tenant has no subscription in it, and `az login`
otherwise refuses with `No subscriptions found`.

Confirm you really are Global Administrator there:

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/me/memberOf" --query "value[].displayName" -o table
```

---

## Step 4 — Run the utility against it

From the project that needs the credentials:

```bash
~/az-iam-group-utils/scripts/cdf-auth-setup.sh \
  --tenant <new-tenant-id> \
  --cluster <cluster> \
  --cdf-project <project> \
  --prefix <something-specific>
```

The script refuses to run if your active `az` session is on a different tenant from `--tenant`,
which is the most common mistake right after creating one — the CLI often stays signed in to the
old tenant.

See [SETUP.md](SETUP.md) for the rest.

---

## Gotchas

| Symptom | Cause |
|---|---|
| **Microsoft Entra ID** option greyed out in the Create dialog | Free or trial account, tenant creation disabled, or missing the Tenant Creator role. See Step 1. |
| `No subscriptions found` on `az login` | New tenants have no subscription. Add `--allow-no-subscriptions`. |
| `403 Authorization_RequestDenied` from the utility | Signed in to the wrong tenant. Check `az account show --query tenantId -o tsv`. |
| New tenant missing from `az account list` | That command lists subscriptions. A tenant with no subscription never appears — this is expected, not a failure. |
| Users from your main org cannot sign in | A new tenant is empty. Invite them as guests, or create accounts. |
| Want to rename the initial domain | Not possible. Add a custom domain, or recreate the tenant. |

---

## Deleting a tenant

1. Sign in to the tenant you want to delete (check the **Directory + subscription** filter).
2. **Microsoft Entra ID → Overview → Delete directory**.

Azure runs a set of preflight checks and blocks deletion while anything remains — subscriptions,
users other than yourself, or registered applications. **Run `terraform -chdir=.cdf-auth destroy`
first** to remove what this utility created, or deletion will fail.

---

## Sources

- [Create a new tenant in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/fundamentals/create-new-tenant)
- [`azurerm_aadb2c_directory`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/aadb2c_directory)
- [`Microsoft.AzureActiveDirectory/ciamDirectories`](https://learn.microsoft.com/en-us/azure/templates/microsoft.azureactivedirectory/ciamdirectories)
