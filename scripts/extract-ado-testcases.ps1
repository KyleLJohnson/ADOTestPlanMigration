$org = $env:ADO_ORG
$project = $env:ADO_PROJECT
$pat = $env:ADO_PAT

$base64Auth = [Convert]::

$url = "https://dev.azure.com/$org/$project/_apis/test/plans?api-version=7.0"

$response = Invoke-RestMethod -Uri $url -Headers @{
    Authorization = "Basic $base64Auth"
}

$response | ConvertTo-Json -Depth 10 | Out-File "./data/raw-ado-testcases.json"
