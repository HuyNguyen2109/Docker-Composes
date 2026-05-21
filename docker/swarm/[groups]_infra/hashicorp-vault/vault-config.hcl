ui = true
disable_mlock = true

storage "postgresql" {
  connection_url = "{{PG_CONNECTION_STRING}}"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}

seal "azurekeyvault" {
  tenant_id      = "{{AZURE_TENANT_ID}}"
  client_id      = "{{AZURE_CLIENT_ID}}"
  client_secret  = "{{AZURE_CLIENT_SECRET}}"
  vault_name     = "{{AZURE_VAULT_NAME}}"
  key_name       = "unseal-key-hcl"
}
