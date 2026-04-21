# Decision: azure-cost Schema 2.2 ETL upgrade

- Issue: #402
- Branch: feat/402-azurecost-schema22
- Summary: Upgraded Invoke-AzureCost and Normalize-AzureCost to emit and normalize missing Schema 2.2 cost fields end to end.
- Key mappings: Pillar=CostOptimization, Frameworks=FinOps Foundation, DeepLinkUrl to Cost Management blade with subscription/resourceGroup query parameters, BaselineTags derived from cost category, ScoreDelta from monthly cost.
- Validation: Invoke-Pester -Path .\tests -CI passed after changes.
