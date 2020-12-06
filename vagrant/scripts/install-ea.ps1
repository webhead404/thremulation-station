# Build authentication information for later requests
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$user = "vagrant"
$password = "vagrant"
$credential = "${user}:${password}"
$credentialBytes = [System.Text.Encoding]::ASCII.GetBytes($credential)
$base64Credential = [System.Convert]::ToBase64String($credentialBytes)
$basicAuthHeader = "Basic $base64Credential"
$headers = @{
  "Authorization" = $basicAuthHeader;
  "kbn-xsrf"      = "reporting"
}
$bodyMsg = @{"forceRecreate" = "true" }
$bodyJson = ConvertTo-Json($bodyMsg)
$kibana_url = "http://192.168.33.10:5601"
$elasticsearch_url = "http://192.168.33.10:9200"

# Retrieve Stack Version
Invoke-WebRequest -UseBasicParsing $elasticsearch_url -OutFile version.json
$agent_version = (Get-Content 'version.json' | ConvertFrom-Json).version.number

# Create Fleet User
Write-Output "Create Fleet User"
Write-Output "Creating fleet user at $kibana_url/api/fleet/setup"
$fleetCounter = 0
do {
  Start-Sleep -Seconds 20
  Write-Output "Trying $fleetCounter times"
  try {
    Write-Output "Creating fleet user with POST request at $kibana_url/api/fleet/setup"
    Invoke-WebRequest -UseBasicParsing -Uri  "$kibana_url/api/fleet/agents/setup" -ContentType "application/json" -Headers $headers -Method POST -body $bodyJson -ErrorAction SilentlyContinue -ErrorVariable SearchError
  }
  catch {
    Write-output "Error Message Array: $searchError"
  }
  Start-Sleep -Seconds 5
  
  # Checking the content output to see if the host is ready.
  try {
    Write-Output "Checking if Fleet Manager is ready with GET request $kibana_url/api/fleet/enrollment-api-keys?page=1&perPage=20"
    $ekIDBody = (Invoke-WebRequest -UseBasicParsing -Uri  "$kibana_url/api/fleet/agent_policies?page=1&perPage=20&sortField=updated_at&sortOrder=desc&kuery=" -ContentType "application/json" -Headers $headers -Method GET  -ErrorVariable SearchError)
    $isReady = (convertfrom-json($ekIDBody.content)).total
  }
  catch {
    Write-output "Error Message Array: $searchError"
  }

  $fleetCounter++
}
until (($isReady -gt 0) -or ($fleetCounter -eq 5) )

# Get Body of Fleet Enrollment API Key
Write-Output "Get Enrollment API Key"
$ApiKeyList = (ConvertFrom-Json(Invoke-WebRequest -UseBasicParsing -Uri  "$kibana_url/api/fleet/enrollment-api-keys" -ContentType "application/json" -Headers $headers -Method GET))

# Get Fleet Token and default policy ID from json message
$ApiKeyId = $ApiKeyList.list[0].id
$ApiKeyActual = (ConvertFrom-Json(Invoke-WebRequest -UseBasicParsing -Uri  "$kibana_url/api/fleet/enrollment-api-keys/$ApiKeyId" -ContentType "application/json" -Headers $headers -Method GET))
$fleetToken = $ApiKeyActual.item[0].api_key
$policyId = $ApiKeyActual.item[0].policy_id

# Configure Fleet output URLs for Kibana and Elasticsearch
Write-Output "Set Kibana Url"
$fleetYMLconfig = @"
{
  "kibana_urls": ["$kibana_url"]
}
"@ | ConvertFrom-Json
$fleetYMLconfigJson = ConvertTo-Json($fleetYMLconfig)
Invoke-WebRequest -UseBasicParsing -Uri "$kibana_url/api/fleet/settings" -ContentType application/json -Headers $headers -Method Put -body $fleetYMLconfigJson -ErrorAction SilentlyContinue -ErrorVariable SearchError -TransferEncoding compress

Write-Output "Set Elasticsearch Url"
$fleetYMLconfig = @"
{
  "hosts": ["$elasticsearch_url"]
}
"@ | ConvertFrom-Json
$fleetYMLconfigJson = ConvertTo-Json($fleetYMLconfig)
$response = Invoke-RestMethod -UseBasicParsing -Uri "$kibana_url/api/fleet/outputs" -ContentType application/json -Headers $headers -Method Get -ErrorAction SilentlyContinue -ErrorVariable SearchError
$id = $response.items.id
Invoke-WebRequest -UseBasicParsing -Uri "$kibana_url/api/fleet/outputs/$id" -ContentType application/json -Headers $headers -Method Put -body $fleetYMLconfigJson -ErrorAction SilentlyContinue -ErrorVariable SearchError -TransferEncoding compress

### Configure Fleet packages ###################################

# Get list of all current packages for package version
$packageList = (convertfrom-json(Invoke-WebRequest -UseBasicParsing -Uri  "$kibana_url/api/fleet/epm/packages?experimental=true" -ContentType "application/json" -Headers $headers -Method GET))

### Enable Endpoint integration
$pkgVer = ($packageList.response | Where-Object { $_.name -eq "endpoint" }).version
$pkgCfg = @"
{
  "name": "security",
  "description": "",
  "namespace": "default",
  "policy_id": "$policyId",
  "enabled": "true",
  "output_id": "",
  "inputs": [],
  "package": {
    "name": "endpoint",
    "title": "Elastic Endpoint Security",
    "version": "$pkgVer"
  }
}
"@ | convertfrom-json
$pkgCfgJson = ConvertTo-Json($pkgCfg)

Write-Output "Enable Security Integration into Default Config in Ingest Manager"
Invoke-WebRequest -UseBasicParsing -Uri  "$kibana_url/api/fleet/package_policies" -ContentType "application/json" -Headers $headers -Method POST -body $pkgCfgJson

### Enable Windows integration
$pkgVer = ($packageList.response | Where-Object { $_.name -eq "windows" }).version
$pkgCfg = @"
{
  "name": "windows",
  "description": "",
  "namespace": "default",
  "policy_id": "$policyId",
  "enabled": "true",
  "output_id": "",
  "inputs": [],
  "package": {
    "name": "windows",
    "title": "Windows",
    "version": "$pkgVer"
  }
}
"@ | convertfrom-json
$pkgCfgJson = ConvertTo-Json($pkgCfg)

Write-Output "Enable Windows Integration into Default Config in Ingest Manager"
Invoke-WebRequest -UseBasicParsing -Uri  "$kibana_url/api/fleet/package_policies" -ContentType "application/json" -Headers $headers -Method POST -body $pkgCfgJson

### Configure Elastic Agent on host ###################################

# TODO: Clean up the temporary file artifacts
$elasticAgentUrl = "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-$agent_version-windows-x86_64.zip"
$agent_install_folder = "C:\Program Files"
$install_dir = "C:\Agent"
New-Item -Path $install_dir -Type directory | Out-Null

if (!(Test-Path $agent_install_folder)) {
  New-Item -Path $agent_install_folder -Type directory | Out-Null
}
Write-Output "Downloading Elastic Agent"
Invoke-WebRequest -UseBasicParsing -Uri $elasticAgentUrl -OutFile "$install_dir\elastic-agent-$agent_version-windows-x86_64.zip"
Write-Output "Installing Elastic Agent..."
Write-Output "Unzipping Elastic Agent from $agent_install_folder\elastic-agent-$agent_version-windows-x86_64.zip to $agent_install_folder"
Expand-Archive -literalpath $install_dir\elastic-agent-$agent_version-windows-x86_64.zip -DestinationPath $agent_install_folder

Rename-Item "$agent_install_folder\elastic-agent-$agent_version-windows-x86_64" "$agent_install_folder\Elastic-Agent"

Write-Output "Running enroll process of Elastic Agent with token: $fleetToken at url: $kibana_url"
#install -f --kibana-url=KIBANA_URL --enrollment-token=ENROLLMENT_KEY
Set-Location 'C:\Program Files\Elastic-Agent'
.\elastic-agent.exe install -f --insecure --kibana-url=$kibana_url --enrollment-token=$fleetToken

# Ensure Elastic Agent is started
if ((Get-Service "Elastic Agent") -eq "Stopped") {
  Write-Output "Starting Agent Service"
  Start-Service "elastic-agent"
}