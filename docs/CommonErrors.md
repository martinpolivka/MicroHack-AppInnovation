# Common errors

## Container Apps OpenTelemetry properties produce BCP037 warnings

**Symptom:** Bicep reports that `appInsightsConfiguration` and
`openTelemetryConfiguration` aren't allowed on `ManagedEnvironmentProperties`.

**Cause:** The stable `Microsoft.App/managedEnvironments@2025-01-01` Bicep type
doesn't expose the managed OpenTelemetry agent properties.

**Solution:** Use the API version shown in the Azure Container Apps OpenTelemetry
documentation:

```bicep
resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  // ...
}
```

Rebuild the template and confirm that the BCP037 warnings are gone.
