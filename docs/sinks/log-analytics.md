# Log Analytics sink (Logs Ingestion API)

This sink pushes `entities.json`-derived findings and entity records to Azure Monitor Logs using the modern **Logs Ingestion API** with a **Data Collection Rule (DCR)**.

## Why this path

- Uses DCR/DCE ingestion: `POST {endpoint}/dataCollectionRules/{dcrImmutableId}/streams/{streamName}?api-version=2023-01-01`
- Supports Sentinel custom tables and DCR transforms.
- Replaces the legacy HTTP Data Collector API, which is deprecated and retires on **2026-09-14**.

References:

- Logs Ingestion API overview: https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview
- DCR overview: https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-overview
- Service limits (Logs Ingestion API): https://learn.microsoft.com/azure/azure-monitor/fundamentals/service-limits#logs-ingestion-api
- Deprecated HTTP Data Collector API: https://learn.microsoft.com/azure/azure-monitor/logs/data-collector-api

## Prerequisites

1. Log Analytics workspace.
2. Custom tables (example):
   - `AzureAnalyzerFindings_CL`
   - `AzureAnalyzerEntities_CL`
3. DCR with stream declarations and stream-to-table mappings.
4. DCE or DCR ingestion endpoint.
5. RBAC on DCR: **Monitoring Metrics Publisher**.

## Config file

Create a JSON file and pass it with `-LogAnalyticsConfig`.

```json
{
  "DceEndpoint": "https://my-dce.eastus-1.ingest.monitor.azure.com",
  "DcrImmutableId": "dcr-000a00a000a00000a000000aa000a0aa",
  "FindingsStream": "Custom-AzureAnalyzerFindings",
  "EntitiesStream": "Custom-AzureAnalyzerEntities",
  "DryRun": false
}
```

## Run

```powershell
.\Invoke-AzureAnalyzer.ps1 `
  -SubscriptionId "<sub-guid>" `
  -SinkLogAnalytics `
  -LogAnalyticsConfig ".\config\log-analytics-sink.json"
```

Dry-run mode writes payload previews to output:

- `log-analytics-findings-dryrun.json`
- `log-analytics-entities-dryrun.json`

## Notes on limits and batching

The sink batches requests to honor Logs Ingestion API limits:

- Max request size: **1 MB**
- Max records per request: **1,500**

## Suggested DCR column mapping

Map finding stream columns to your table schema, including idempotency keys:

- `RunId` (string)
- `EntityId` (string)
- `FindingId` (string)

Additional fields follow `FindingRow` shape (`Source`, `Category`, `Title`, `Severity`, `Compliant`, `Remediation`, etc.) and entity metadata in the entity stream.

## Sentinel sample KQL

Find latest non-compliant findings by severity:

```kusto
AzureAnalyzerFindings_CL
| where Compliant == false
| summarize Findings=count() by Severity, Source
| order by Findings desc
```

Join findings with entities:

```kusto
AzureAnalyzerFindings_CL
| where Compliant == false
| join kind=leftouter AzureAnalyzerEntities_CL on EntityId
| project TimeGenerated, Severity, Title, Source, EntityId, DisplayName, SubscriptionId
| order by TimeGenerated desc
```

Join custom findings to Sentinel incidents by subscription context:

```kusto
let Findings =
    AzureAnalyzerFindings_CL
    | where Compliant == false
    | project FindingTime=TimeGenerated, Severity, Title, EntityId, SubscriptionId, Source;
SecurityIncident
| project IncidentNumber, IncidentName=Title, IncidentTime=TimeGenerated, SubscriptionId=tostring(AdditionalData.subscriptionId)
| join kind=leftouter Findings on SubscriptionId
| project IncidentTime, IncidentNumber, IncidentName, Severity, Title, EntityId, Source
| order by IncidentTime desc
```
