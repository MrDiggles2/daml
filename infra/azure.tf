# Copyright (c) 2023 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

locals {
  azure-admin-login = "adminuser"
  azure-pub-key     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCygLXwXmrkMYpxLtyolmOqodZ6w6DZINDLrCnpEpyykWbUdEmbTVYclF92dRLTd84TyQO5lfL7eAUAi6KWYE0DNIXV/Jl93iM+80/i3QqIMjcydzkkkSNJHDPECJoVx+ftm0tCOWZXLudsHgHkMu0Vx2R9XvfUB+MY5sU50NV6wwmAAyZezW8l51/vcPeLb5YX7hV8+VjF9zv5f7SxZGsfALYB2CwddwPoO+/xrnj/Vz9jWsO5y4I7ia1tAs3QOabtz9UPfvVxIoDnEAojgVnsb7GvB4SvxraEQHNLwXcRmzCPPyznOhiAdGKd1kpEMnbD7lKQrKdHX2PdVJZB/PF1ekv62HD6ZuzKmrcB7qUpj6qkDCfaPCw1psTefXFjK53Q2LffZVhanOw+Oq7J1Gdo7phl40ipQyHHr/jp0pMmQ7mZhXnbrQE4H4csMoMbzWH9WcJ+qowBUHMb55Ai0WcVho0/w7+FPAiVDyUobxpaZnqBOV+/n/hC9kkkC1bfokP6oFEi6w4m1/g1LlgWLo+ex9H2ebOt9yiUBsWXwWUyrvbtCANpo510Ss9rCj9NS9vu7iH3GV9JcpaGs1AF7NXNduwI+LCiYK+smBo0T1I8Sq/TpoYtDCAhoGZth4sppetEgMNOFsri7ZZiu0NiJLpEhhVou06CMM/KSwBU2PzeSw== Azure Self Hosted Runners"
}

resource "azurerm_virtual_network" "ubuntu" {
  name                = "ubuntu"
  location            = azurerm_resource_group.daml-ci.location
  resource_group_name = azurerm_resource_group.daml-ci.name
  address_space       = ["10.0.0.0/16"]

  subnet {
    name           = "subnet"
    address_prefix = "10.0.1.0/24"
    security_group = azurerm_network_security_group.ubuntu.id
  }
}

resource "azurerm_nat_gateway" "nat" {
  name                = "nat"
  location            = azurerm_resource_group.daml-ci.location
  resource_group_name = azurerm_resource_group.daml-ci.name
}

resource "azurerm_public_ip_prefix" "nat" {
  name                = "nat-ip-prefix"
  location            = azurerm_resource_group.daml-ci.location
  resource_group_name = azurerm_resource_group.daml-ci.name
  prefix_length       = 28
}

resource "azurerm_nat_gateway_public_ip_prefix_association" "nat" {
  nat_gateway_id      = azurerm_nat_gateway.nat.id
  public_ip_prefix_id = azurerm_public_ip_prefix.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "nat" {
  subnet_id      = one(azurerm_virtual_network.ubuntu.subnet).id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

resource "azurerm_network_security_group" "ubuntu" {
  name                = "ubuntu"
  location            = azurerm_resource_group.daml-ci.location
  resource_group_name = azurerm_resource_group.daml-ci.name

  security_rule {
    name                       = "deny-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_linux_virtual_machine" "daily-reset" {
  name                  = "daily-reset"
  location              = azurerm_resource_group.daml-ci.location
  resource_group_name   = azurerm_resource_group.daml-ci.name
  network_interface_ids = [azurerm_network_interface.daily-reset.id]
  size                  = "Standard_DS1_v2"

  os_disk {
    caching              = "ReadOnly"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = "30"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(<<STARTUP
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y jq
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

echo "$(date -Is -u) boot" > /root/log

az login --identity > /root/log

az configure --defaults group=${azurerm_resource_group.daml-ci.name} > /root/log

cat <<'CRON' > /root/daily-reset.sh
#!/usr/bin/env bash
set -euo pipefail
echo "$(date -Is -u) start"

AZURE_PAT=${secret_resource.vsts-token.value}

scale_sets="$(az vmss list | jq -c '[.[] | {name, size: .sku.capacity}]')"

echo "$(date -Is -u) Shutting down all machines"

for set in $(echo $scale_sets | jq -r '.[] | .name'); do
  echo "$(date -Is -u) - Setting scale set $set size to 0"
  az vmss scale -n $set --new-capacity 0 >/dev/null
done

echo "$(date -Is -u) Waiting for scale sets to adapt"

sleep 300

echo "$(date -Is -u) Removing all nodes from Azure Pipelines"

for pool in 11 18; do
  agents=$(curl -s -u :$AZURE_PAT "https://dev.azure.com/digitalasset/_apis/distributedtask/pools/$pool/agents?api-version=7.0" | jq -c '[.value[] | {name,id}]')
  for idx in $(seq 0 $(echo "$agents" | jq 'length - 1')); do
    name=$(echo "$agents" | jq -r ".[$idx].name")
    id=$(echo "$agents" | jq -r ".[$idx].id")
    if [[ "$name" =~ d[uw][12]-.* ]]; then
      echo "$(date -Is -u) - Removing agent $name ($id)"
      curl -s -u :$AZURE_PAT -XDELETE "https://dev.azure.com/digitalasset/_apis/distributedtask/pools/$${pool}/agents/$${id}?api-version=7.0" &>/dev/null
    else
      echo "$(date -Is -u) - Leaving agent $name untouched"
    fi
  done
done

echo "$(date -Is -u) Bringing scale sets back up"

for set in $(echo $scale_sets | jq -r '.[] | .name'); do
  size=$(echo $scale_sets | jq --arg set $set -r '.[] | select (.name == $set) | .size')
  echo "$(date -Is -u) - Setting scale set $set size back to $size"
  az vmss scale -n $set --new-capacity $size >/dev/null
done

echo "$(date -Is -u) end"
CRON

chmod +x /root/daily-reset.sh

cat <<CRONTAB >> /etc/crontab
0 4 * * * root /root/daily-reset.sh >> /root/log 2>&1
CRONTAB

tail -f /root/log

STARTUP
  )

  computer_name                   = "daily-reset"
  admin_username                  = local.azure-admin-login
  disable_password_authentication = true

  admin_ssh_key {
    username   = local.azure-admin-login
    public_key = local.azure-pub-key
  }
  identity {
    type = "SystemAssigned"
  }

  # required to get console output in Azure UI
  boot_diagnostics {
    storage_account_uri = null
  }
}

resource "azurerm_network_interface" "daily-reset" {
  name                = "daily-reset"
  location            = azurerm_resource_group.daml-ci.location
  resource_group_name = azurerm_resource_group.daml-ci.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = one(azurerm_virtual_network.ubuntu.subnet).id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_role_definition" "daily-reset" {
  name  = "daily-reset"
  scope = azurerm_resource_group.daml-ci.id

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/virtualMachineScaleSets/write",
    ]
  }
}

resource "azurerm_role_assignment" "daily-reset" {
  scope              = azurerm_resource_group.daml-ci.id
  role_definition_id = azurerm_role_definition.daily-reset.role_definition_resource_id
  principal_id       = azurerm_linux_virtual_machine.daily-reset.identity[0].principal_id
}
