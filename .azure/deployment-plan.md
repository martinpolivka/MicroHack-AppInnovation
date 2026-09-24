# Azure Deployment Plan

> **Status:** Validated

Generated: 2026-09-24T11:00:58Z

---

## 1. Project Overview

**Goal:** Add the Azure Container Apps managed OpenTelemetry agent to the existing
application infrastructure and export application traces and logs to workspace-based
Azure Application Insights.

**Path:** Add Components

The existing Java application is already instrumented with the OpenTelemetry SDK and a
Logback OpenTelemetry appender. The Container App currently overrides the managed
agent's endpoint and disables the SDK, so those overrides must be removed when the
environment-level agent is enabled.

---

## 2. Requirements

| Attribute | Value |
|-----------|-------|
| Classification | Development / workshop |
| Scale | Small |
| Budget | Cost-Optimized |
| **Subscription** | `mpolivka-5` (`ba8bc294-9b14-4eb2-8b4a-d094818fbec5`), user-confirmed |
| **Location** | Sweden Central, user-confirmed |

---

## 3. Components Detected

| Component | Type | Technology | Path |
|-----------|------|------------|------|
| Catalog application | Web application | Java 21, Spring Boot 4, OpenTelemetry SDK | `java/` |
| Application infrastructure | Infrastructure as code | Bicep, Azure Container Apps | `bicep/` |
| Managed environment | Container hosting | Azure Container Apps workload profiles | `bicep/main.bicep` |

---

## 4. Recipe Selection

**Selected:** Bicep

**Rationale:** The target infrastructure is already defined in a single Bicep template.
The requested monitoring resources and managed agent configuration can be added
surgically without changing the deployment workflow or introducing another IaC tool.

---

## 5. Architecture

**Stack:** Containers

### Service Mapping

| Component | Azure Service | SKU |
|-----------|---------------|-----|
| Catalog application | Azure Container Apps | Consumption workload profile |
| Managed telemetry collector | Container Apps managed OpenTelemetry agent | Microsoft-managed, no additional compute charge |
| Telemetry destination | Application Insights | Workspace-based |
| Telemetry storage | Log Analytics workspace | PerGB2018, 30-day retention |

### Data Flow

1. The Java OpenTelemetry SDK emits traces and Logback log records over OTLP/gRPC.
2. The Container Apps environment automatically injects the managed agent endpoint and
   protocol into the container.
3. The managed agent exports traces and logs to Application Insights.
4. Application Insights stores the telemetry in the linked Log Analytics workspace.
5. Metrics export is disabled in the app configuration because the managed Application
   Insights destination supports traces and logs, not OpenTelemetry metrics.

### Planned File Changes

- Add Log Analytics and workspace-based Application Insights resources to
  `bicep/main.bicep`.
- Configure `appInsightsConfiguration` and `openTelemetryConfiguration` on the existing
  managed environment with `appInsights` destinations for traces and logs.
- Remove the explicit local OTLP endpoint parameter and the `OTEL_SDK_DISABLED=true`
  override so Container Apps can inject the managed agent settings.
- Set `OTEL_METRICS_EXPORTER=none` because Application Insights isn't a supported metrics
  destination for the managed agent.
- Add monitoring resource outputs and regenerate `bicep/main.json`.
- Update `bicep/README.md` with deployment behavior and verification instructions.
- Record the architecture decision in `docs/ImplementationLog.md`.

### Security Notes

- No new credential parameter or secret is introduced.
- The Application Insights connection string is passed directly between Azure resources.
  Microsoft documents that it isn't a security token.
- `DisableLocalAuth` remains `false` because the Container Apps managed OpenTelemetry
  agent currently requires Application Insights local authentication.

---

## 6. Provisioning Limit Checklist

The Azure Quota CLI was attempted first for both new provider namespaces. Neither
`Microsoft.OperationalInsights` nor `Microsoft.Insights` returned quota records. Azure
Resource Graph reports zero resources of either type in Sweden Central for the confirmed
subscription, so official Azure limits are used as the documented fallback.

| Resource Type | Number to Deploy | Total After Deployment | Limit/Quota | Notes |
|---------------|------------------|------------------------|-------------|-------|
| `Microsoft.OperationalInsights/workspaces` | 1 | 1 in Sweden Central | No workspace-count limit for PerGB2018 | Azure Quota CLI unsupported; Azure Resource Graph count 0; official Azure Monitor service limits |
| `Microsoft.Insights/components` | 1 | 1 in Sweden Central | 800 instances of a resource type per resource group | Azure Quota CLI unsupported; Azure Resource Graph count 0; official Azure Resource Manager limit |

**Status:** All added resources are within documented limits.

---

## 7. Validation Proof

| Check | Command / Tool | Result |
|-------|----------------|--------|
| Bicep formatting | Bicep formatter | Passed |
| Bicep compilation | `az bicep build --file bicep/main.bicep --outfile bicep/main.json` | Passed without diagnostics after selecting the documented managed-environment preview API |
| Parameter compilation | `az bicep build-params --file bicep/main.bicepparam --stdout` with validation-only environment values | Passed |
| Bicep linting | `az bicep lint --file bicep/main.bicep` | Passed without diagnostics |
| Azure target validation | `validate-deployment.sh` against `rg-user001` in subscription `mpolivka-5` | Passed |
| Azure what-if | `validate-deployment.sh` against `rg-user001` | Passed; Create: 7, Modify: 31, Delete: 22. Preview only; no deployment performed |
| Azure Policy | Azure MCP `policy_assignment_list` at `rg-user001` scope | Retrieved inherited assignments; Azure target validation and what-if passed with enforcement enabled |
| Generated ARM assertions | Focused search of `bicep/main.bicep` and `bicep/main.json` | Linked workspace, Application Insights destination, trace/log routes, and metrics disablement present; local endpoint and SDK-disable overrides absent |
| Java build and tests | `cd java && ./mvnw test` | Passed: 34 tests, 0 failures, 0 errors, 0 skipped |
| Whitespace validation | `git diff --check` | Passed |

No Azure resources were deployed.

---

## 8. Execution Checklist

### Phase 1: Planning

- [x] Analyze workspace
- [x] Gather requirements
- [x] Confirm subscription and location with user
- [x] Prepare resource inventory
- [x] Fetch quotas and validate capacity
- [x] Scan codebase
- [x] Select Bicep recipe
- [x] Plan architecture
- [x] User approved this plan

### Phase 2: Execution

- [x] Add monitoring resources and managed OpenTelemetry configuration
- [x] Update component documentation and implementation log
- [x] Format and compile Bicep
- [x] Update status to `Ready for Validation`
- [x] Invoke `azure-validate`

### Phase 3: Validation

- [x] All validation checks pass
  - [x] Core validation (Azure CLI, authentication, Bicep build, deployment validation, and what-if)
  - [x] Bicep linting
  - [x] Azure Policy validation

## 9. Role Assignment Verification

- **Status:** Verified
- **Identities checked:** `mh-catalog-identity`, `mh-github-actions-identity`
- **Roles confirmed:**
  - The catalog identity receives `AcrPull` at the specific Container Registry scope.
  - The GitHub Actions deployment identity receives Contributor at resource-group scope
    for its intended management-plane deployment operations.
- **Monitoring authentication:** The managed OpenTelemetry agent uses the Application
  Insights connection string and requires no additional managed-identity role.
- **Issues:** None introduced by the monitoring changes.
