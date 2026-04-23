// Realistic Terraform fixture for E2E wrapper coverage (#665).
// The HCL is well-formed; tests mock terraform/trivy output to
// simulate validate diagnostics and trivy misconfiguration findings.
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_storage_account" "example" {
  name                     = "examplestorage"
  resource_group_name      = "rg-example"
  location                 = "westeurope"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
