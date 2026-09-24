# Azure application infrastructure

This template deploys a PostgreSQL Flexible Server using the Burstable B1ms SKU,
PostgreSQL 16, and a firewall rule for one client IPv4 address. It also deploys
an Azure Container Registry, a workload-profile Container Apps environment, the
catalog Container App, Azure Files shares for the seed JSON and images, and an
Azure Load Testing resource. The app uses a user-assigned managed identity with
`AcrPull` instead of registry admin credentials.

The template also creates a separate `mh-github-actions-identity` user-assigned
identity for CI/CD. Its federated credential trusts GitHub's OIDC issuer only for
the repository configured by `githubRepository`. Separate subjects support the
`main` branch and the `staging` and `production` GitHub environments. The identity
receives the Contributor role at the current resource-group scope, so the workflow
can push images and update the Container App without a stored Azure client secret.

Set `containerRegistrySku` in `main.bicepparam` to `Standard` or `Premium` when
the workload requires features beyond the default Basic tier.

## Deploy

1. Update `clientIpAddress` and, if needed, the other non-secret values in
   `main.bicepparam`. Set `githubRepository` in `owner/name` format; the checked-in
   value is `martinpolivka/MicroHack-AppInnovation`.
2. Set the secrets in your shell:

   ```bash
   export POSTGRES_ADMIN_PASSWORD='<strong-password>'
   export PERFTEST_API_KEY='<performance-endpoint-key>'
   ```

3. For a new resource group, deploy the supporting infrastructure first. The
   switch avoids creating the Container App before its image exists in the new
   registry. The account running this deployment must be allowed to create role
   assignments, such as through Owner or User Access Administrator.

   ```bash
   az login
   az deployment group create \
       --name application-infrastructure \
     --resource-group '<resource-group-name>' \
      --parameters ./main.bicepparam \
      deployContainerApp=false
   ```

4. Upload the application data to the `seed` and `images` file shares. The seed
    file must be stored as `catalog.json` at the root of the `seed` share, and the
    contents of `data/images` must be stored at the root of the `images` share.

5. Build the application image from the repository root, then redeploy without
   the override to create the Container App and its first application revision:

    ```bash
    registryName=$(az acr list \
       --resource-group '<resource-group-name>' \
       --query '[0].name' \
       --output tsv)

    az acr build \
       --registry "$registryName" \
       --image lego-catalog/app:latest \
       ./java

    az deployment group create \
       --name application-infrastructure \
       --resource-group '<resource-group-name>' \
       --parameters ./main.bicepparam
    ```

The password and API key parameters are marked `@secure()` and read from the
environment, so they are not stored in the parameter file. The database password
is exposed to the application only through a Container Apps secret reference.

## Configure GitHub Actions federation

After deployment, configure these GitHub Actions repository variables under
**Settings > Secrets and variables > Actions**:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Deployment output `githubActionsIdentityClientId` |
| `AZURE_TENANT_ID` | `az account show --query tenantId --output tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id --output tsv` |
| `RESOURCE_GROUP_NAME` | Name of the deployed resource group |
| `ACR_NAME` | Deployment output `containerRegistryName` |

Read both identity outputs from the deployment with:

```bash
az deployment group show \
   --name application-infrastructure \
   --resource-group '<resource-group-name>' \
   --query 'properties.outputs.{clientId:githubActionsIdentityClientId.value,principalId:githubActionsIdentityPrincipalId.value}'
```

The simple workflow can use the
`repo:<owner>/<repository>:ref:refs/heads/main` subject. The revision workflow uses
`repo:<owner>/<repository>:environment:staging` while creating a zero-traffic revision
and `repo:<owner>/<repository>:environment:production` while promoting it. Create both
GitHub environments with those exact lowercase names and add required reviewers to
`production`. Manual workflow runs can start from any branch when every Azure login job
uses one of these environment-scoped credentials.