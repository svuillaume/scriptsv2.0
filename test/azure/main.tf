
provider "azurerm" {
  features {}
}

variable "prefix" {
  default = "tfvmex"
}

resource "random_password" "vm_password" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "random_password" "sql_password" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-resources"
  location = "East US"
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_interface" "main" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "testconfiguration1"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_virtual_machine" "main" {
  name                  = "${var.prefix}-vm"
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  network_interface_ids = [azurerm_network_interface.main.id]
  vm_size               = "Standard_DS1_v2"

  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }
  storage_os_disk {
    name              = "myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "hostname"
    admin_username = "testadmin"
    admin_password = random_password.vm_password.result
  }
  os_profile_linux_config {
    # lacework-iac-azure-security-3 (CRITICAL): enforce SSH key auth, disable passwords
    disable_password_authentication = true
  }
  tags = {
    environment = "staging"
  }
}

resource "azurerm_resource_group" "example" {
  name     = "example-resources"
  location = "West US"
}

resource "random_id" "storageaccount" {
  byte_length = 8
}

resource "random_id" "sqlserver" {
  byte_length = 8
}

# lacework-iac-azure-encryption-13 (HIGH): customer-managed key for storage encryption
resource "azurerm_key_vault" "example" {
  name                = "kv-${lower(random_id.storageaccount.hex)}"
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  purge_protection_enabled = true
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault_key" "storage_cmk" {
  name         = "storage-cmk"
  key_vault_id = azurerm_key_vault.example.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]
}

resource "azurerm_storage_account" "example" {
  name                     = lower(random_id.storageaccount.hex)
  resource_group_name      = azurerm_resource_group.example.name
  location                 = azurerm_resource_group.example.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # lacework-iac-azure-storage-5 (HIGH): disable public network access
  public_network_access_enabled = false

  # lacework-iac-azure-storage-3 (LOW): enable storage analytics logging
  blob_properties {
    logging {
      delete                = true
      read                  = true
      write                 = true
      version               = "1.0"
      retention_policy_days = 7
    }
  }

  # lacework-iac-azure-encryption-13 (HIGH): use customer-managed key
  identity {
    type = "SystemAssigned"
  }

  # lacework-iac-azure-network-3 (HIGH): default deny + allow trusted Microsoft services
  # lacework-iac-azure-storage-1 (HIGH): bypass AzureServices for trusted Microsoft services
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices", "Logging", "Metrics"]
  }
}

resource "azurerm_storage_account_customer_managed_key" "example" {
  storage_account_id = azurerm_storage_account.example.id
  key_vault_id       = azurerm_key_vault.example.id
  key_name           = azurerm_key_vault_key.storage_cmk.name
}

resource "azurerm_mssql_server" "example1" {
  name                         = "example-sqlserver-${random_id.sqlserver.hex}"
  resource_group_name          = azurerm_resource_group.example.name
  location                     = azurerm_resource_group.example.location
  version                      = "12.0"
  administrator_login          = "4dm1n157r470r"
  administrator_login_password = random_password.sql_password.result

  # lacework-iac-azure-network-23 (HIGH): disable public network access
  public_network_access_enabled = false

  # lacework-iac-azure-general-16 (LOW): Azure AD authentication for SQL Server
  azuread_administrator {
    login_username = "AzureAD Admin"
    object_id      = data.azurerm_client_config.current.object_id
    tenant_id      = data.azurerm_client_config.current.tenant_id
  }
}

resource "azurerm_mssql_database" "test" {
  name           = "acctest-db-d"
  server_id      = azurerm_mssql_server.example1.id
  collation      = "SQL_Latin1_General_CP1_CI_AS"
  license_type   = "LicenseIncluded"
  max_size_gb    = 4
  read_scale     = true
  sku_name       = "BC_Gen5_2"
  zone_redundant = false

  tags = {
    foo = "bar"
  }
}

resource "azurerm_mssql_database_extended_auditing_policy" "example" {
  database_id                             = azurerm_mssql_database.test.id
  storage_endpoint                        = azurerm_storage_account.example.primary_blob_endpoint
  storage_account_access_key              = azurerm_storage_account.example.primary_access_key
  storage_account_access_key_is_secondary = true
  # lacework-iac-azure-network-6 (LOW): retain audit logs for at least 90 days
  retention_in_days = 90
}

# lacework-iac-azure-security-38 (MEDIUM): SQL server security alert policy
resource "azurerm_mssql_server_security_alert_policy" "example" {
  resource_group_name = azurerm_resource_group.example.name
  server_name         = azurerm_mssql_server.example1.name
  state               = "Enabled"
  email_account_admins = true
  retention_days      = 90
}

# lacework-iac-azure-security-38 (MEDIUM): SQL server vulnerability assessment
resource "azurerm_mssql_server_vulnerability_assessment" "example" {
  server_security_alert_policy_id = azurerm_mssql_server_security_alert_policy.example.id
  storage_container_path          = "${azurerm_storage_account.example.primary_blob_endpoint}vulnerability-assessment/"
  storage_account_access_key      = azurerm_storage_account.example.primary_access_key

  recurring_scans {
    enabled                   = true
    email_subscription_admins = true
  }
}

resource "azurerm_resource_group" "example2" {
  name     = "LoadBalancerRG"
  location = "West US"
}

resource "azurerm_public_ip" "example2" {
  name                = "PublicIPForLB"
  location            = "West US"
  resource_group_name = azurerm_resource_group.example2.name
  allocation_method   = "Static"
}

resource "azurerm_lb" "example2" {
  name                = "TestLoadBalancer"
  location            = "West US"
  resource_group_name = azurerm_resource_group.example2.name

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = azurerm_public_ip.example2.id
  }
}

resource "azurerm_virtual_network" "example2" {
  name                = "test"
  location            = azurerm_resource_group.example2.location
  resource_group_name = azurerm_resource_group.example2.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "example2" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.example2.name
  virtual_network_name = azurerm_virtual_network.example2.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "example3" {
  name                = "test"
  location            = azurerm_resource_group.example2.location
  resource_group_name = azurerm_resource_group.example2.name

  allocation_method = "Dynamic"
}
