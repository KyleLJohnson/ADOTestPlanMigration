# Simplified placeholder logic
# Extend with:
# - Parse TRX XML
# - Map to ADO TestCase IDs
# - POST to ADO Test Runs API
# Simplified placeholder logic
# Extend with:
# - Parse TRX XML
# - Map to ADO TestCase IDs
# - POST to ADO Test Runs API
<#
.SYNOPSIS
Publishes .NET TRX test results back to Azure DevOps Test Runs using Entra authentication.

.DESCRIPTION
This script:
1. Reads a TRX file produced by dotnet test
2. Reads mapping/testcase-mapping.json
3. Creates an automated Azure DevOps test run
4. Publishes each mapped test result back to ADO

Required environment variables:
- ADO_ORG
- ADO_PROJECT

Optional environment variables:
- ADO_BUILD_ID
- GITHUB_RUN_ID
- GITHUB_REPOSITORY
- GITHUB_SHA

Prerequisites:
- Azure CLI installed and authenticated (az login)

Example:
./scripts/publish-test-results.ps1 `
  -TrxPath "./data/test-results/results.trx" `
  -MappingPath "./mapping/testcase-mapping.json"
#>

param(
    [string]$TrxPath = "./data/test-results/results.trx",
    [string]$MappingPath = "./mapping/testcase-mapping.json",
    [string]$RunName = "GitHub .NET Test Run",
    [string]$ApiVersion = "7.1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Get-EntraAccessToken {
    param(
        [Parameter(Mandatory = $false)]
        [string]$TenantId = $null
    )

    Write-Info "Acquiring Entra access token using Azure CLI..."

    try {
        # Azure DevOps resource ID for token scope
        $adoResourceId = "499b84ac-1321-427f-aa17-267ca6975798"
        
        # Get token using az account get-access-token
        $tokenJson = az account get-access-token --resource $adoResourceId 2>$null | ConvertFrom-Json
        
        if (-not $tokenJson.accessToken) {
            throw "Failed to retrieve access token. Ensure you are logged in with 'az login'"
        }
        
        # Get current user info
        $accountInfo = az account show 2>$null | ConvertFrom-Json
        Write-Info "Authenticated as: $($accountInfo.user.name)"
        Write-Debug "[Get-EntraAccessToken] User: $($accountInfo.user.name) (ID: $($accountInfo.user.name))"
        Write-Debug "[Get-EntraAccessToken] Token acquired for Azure DevOps resource"
        
        return $tokenJson.accessToken
    }
    catch {
        throw "Failed to get Entra token: $_. Please run 'az login' first and ensure the account is a member of your Azure DevOps organization."
    }
}

function Get-AdoAuthHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    return @{
        Authorization = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }
}

function Convert-TrxOutcomeToAdoOutcome {
    param([string]$TrxOutcome)

    switch ($TrxOutcome) {
        "Passed" { return "Passed" }
        "Failed" { return "Failed" }
        "Error" { return "Failed" }
        "Timeout" { return "Failed" }
        "Aborted" { return "Aborted" }
        "Inconclusive" { return "Inconclusive" }
        "NotExecuted" { return "NotExecuted" }
        default { return "NotExecuted" }
    }
}

function Convert-DurationToMilliseconds {
    param([string]$Duration)

    if ([string]::IsNullOrWhiteSpace($Duration)) {
        return 0
    }

    try {
        return [int][TimeSpan]::Parse($Duration).TotalMilliseconds
    }
    catch {
        Write-Warn "Could not parse duration '$Duration'. Defaulting to 0 ms."
        return 0
    }
}

function Get-TestCaseMappings {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Mapping file not found: $Path"
    }

    $mappingJson = Get-Content $Path -Raw | ConvertFrom-Json

    $lookup = @{}

    foreach ($suite in $mappingJson.testSuites) {
        foreach ($testCase in $suite.testCases) {
            $fqn = $testCase.automation.fullyQualifiedName

            if ([string]::IsNullOrWhiteSpace($fqn)) {
                Write-Warn "Skipping mapping entry with no fullyQualifiedName."
                continue
            }

            $lookup[$fqn] = [pscustomobject]@{
                AdoTestCaseId      = $testCase.adoTestCaseId
                AdoTestPointId     = $testCase.adoTestPointId
                Title              = $testCase.title
                FullyQualifiedName = $fqn
                SuiteId            = $suite.suiteId
                SuiteName          = $suite.suiteName
                Priority           = if ($testCase.priority) { $testCase.priority } else { 2 }
            }
        }
    }

    return $lookup
}

function Get-TrxResults {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "TRX file not found: $Path"
    }

    [xml]$trx = Get-Content $Path

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($trx.NameTable)
    $namespaceManager.AddNamespace("trx", "http://microsoft.com/schemas/VisualStudio/TeamTest/2010")

    # Build lookup from test execution ID to fully qualified test name.
    $testDefinitions = @{}

    $unitTests = $trx.SelectNodes("//trx:TestDefinitions/trx:UnitTest", $namespaceManager)

    foreach ($unitTest in $unitTests) {
        $executionId = $unitTest.Execution.id
        $testMethod = $unitTest.TestMethod

        if ($null -eq $testMethod) {
            continue
        }

        $className = $testMethod.className
        $methodName = $testMethod.name

        # MSTest often stores className as something like:
        # SampleTests.LoginTests, SampleTests, Version=...
        # Keep only the type name before the comma.
        if ($className -and $className.Contains(",")) {
            $className = $className.Split(",")[0].Trim()
        }

        $fullyQualifiedName = "$className.$methodName"

        if ($executionId) {
            $testDefinitions[$executionId] = $fullyQualifiedName
        }
    }

    $results = @()
    $unitTestResults = $trx.SelectNodes("//trx:Results/trx:UnitTestResult", $namespaceManager)

    foreach ($result in $unitTestResults) {
        $executionId = $result.executionId
        $fqn = $null

        if ($executionId -and $testDefinitions.ContainsKey($executionId)) {
            $fqn = $testDefinitions[$executionId]
        }
        else {
            # Fallback: sometimes testName already equals the FQN.
            $fqn = $result.testName
        }

        $errorMessage = $null
        $stackTrace = $null

        $messageNode = $result.SelectSingleNode("trx:Output/trx:ErrorInfo/trx:Message", $namespaceManager)
        $stackNode = $result.SelectSingleNode("trx:Output/trx:ErrorInfo/trx:StackTrace", $namespaceManager)

        if ($messageNode) {
            $errorMessage = $messageNode.InnerText
        }

        if ($stackNode) {
            $stackTrace = $stackNode.InnerText
        }

        $results += [pscustomobject]@{
            FullyQualifiedName = $fqn
            TestName           = $result.testName
            Outcome            = Convert-TrxOutcomeToAdoOutcome $result.outcome
            DurationInMs       = Convert-DurationToMilliseconds $result.duration
            StartTime          = $result.startTime
            EndTime            = $result.endTime
            ComputerName       = $result.computerName
            ErrorMessage       = $errorMessage
            StackTrace         = $stackTrace
        }
    }

    return $results
}

function New-AdoTestRun {
    param(
        [string]$Organization,
        [string]$Project,
        [hashtable]$Headers,
        [string]$Name,
        [string]$ApiVersion,
        [object]$MappingRoot
    )

    $runComment = "Published from GitHub Actions / dotnet test TRX"

    if ($env:GITHUB_REPOSITORY) {
        $runComment += " | Repo: $($env:GITHUB_REPOSITORY)"
    }

    if ($env:GITHUB_RUN_ID) {
        $runComment += " | GitHub Run ID: $($env:GITHUB_RUN_ID)"
    }

    if ($env:GITHUB_SHA) {
        $runComment += " | Commit: $($env:GITHUB_SHA)"
    }

    $body = @{
        name      = $Name
        automated = $true
        state     = "InProgress"
        comment   = $runComment
    }

    if ($MappingRoot.testPlanId) {
        $body.plan = @{
            id = "$($MappingRoot.testPlanId)"
        }
    }

    if ($env:ADO_BUILD_ID) {
        $body.build = @{
            id = "$($env:ADO_BUILD_ID)"
        }
    }

    $json = $body | ConvertTo-Json -Depth 20

    $uri = "https://dev.azure.com/$Organization/$Project/_apis/test/runs?api-version=$ApiVersion"

    Write-Info "Creating ADO test run: $Name"

    return Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $Headers `
        -Body $json
}

function Add-AdoTestResults {
    param(
        [string]$Organization,
        [string]$Project,
        [hashtable]$Headers,
        [int]$RunId,
        [array]$ResultsPayload,
        [string]$ApiVersion
    )

    if ($ResultsPayload.Count -eq 0) {
        Write-Warn "No mapped test results to publish."
        return $null
    }

    $uri = "https://dev.azure.com/$Organization/$Project/_apis/test/Runs/$RunId/results?api-version=$ApiVersion"

    $json = $ResultsPayload | ConvertTo-Json -Depth 30

    Write-Info "Publishing $($ResultsPayload.Count) test result(s) to ADO run ID $RunId"

    return Invoke-RestMethod `
        -Method Post `
        -Uri $uri `
        -Headers $Headers `
        -Body $json
}

function Complete-AdoTestRun {
    param(
        [string]$Organization,
        [string]$Project,
        [hashtable]$Headers,
        [int]$RunId,
        [string]$ApiVersion
    )

    $body = @{
        state = "Completed"
    } | ConvertTo-Json -Depth 10

    $uri = "https://dev.azure.com/$Organization/$Project/_apis/test/runs/$RunId?api-version=$ApiVersion"

    Write-Info "Completing ADO test run ID $RunId"

    return Invoke-RestMethod `
        -Method Patch `
        -Uri $uri `
        -Headers $Headers `
        -Body $body
}

# -----------------------------
# Main
# -----------------------------

$adoOrg = $env:ADO_ORG
$adoProject = $env:ADO_PROJECT

if ([string]::IsNullOrWhiteSpace($adoOrg)) {
    throw "Missing environment variable: ADO_ORG"
}

if ([string]::IsNullOrWhiteSpace($adoProject)) {
    throw "Missing environment variable: ADO_PROJECT"
}

Write-Info "ADO Organization: $adoOrg"
Write-Info "ADO Project: $adoProject"
Write-Info "TRX Path: $TrxPath"
Write-Info "Mapping Path: $MappingPath"

# Acquire Entra access token
$accessToken = Get-EntraAccessToken
$headers = Get-AdoAuthHeader -AccessToken $accessToken

$mappingRoot = Get-Content $MappingPath -Raw | ConvertFrom-Json
$mappingLookup = Get-TestCaseMappings -Path $MappingPath
$trxResults = Get-TrxResults -Path $TrxPath

Write-Info "Loaded $($mappingLookup.Count) mapping entry/entries."
Write-Info "Loaded $($trxResults.Count) TRX result(s)."

$adoResultsPayload = @()
$unmappedResults = @()

foreach ($trxResult in $trxResults) {
    $fqn = $trxResult.FullyQualifiedName

    if (-not $mappingLookup.ContainsKey($fqn)) {
        $unmappedResults += $trxResult
        Write-Warn "No mapping found for TRX result: $fqn"
        continue
    }

    $mapped = $mappingLookup[$fqn]

    $resultPayload = @{
        testCaseTitle     = $mapped.Title
        automatedTestName = $mapped.FullyQualifiedName
        priority          = [int]$mapped.Priority
        outcome           = $trxResult.Outcome
        state             = "Completed"
        durationInMs      = [int]$trxResult.DurationInMs
        comment           = "Published from GitHub-hosted .NET test execution"
        computerName      = $trxResult.ComputerName
        testCase          = @{
            id   = "$($mapped.AdoTestCaseId)"
            name = $mapped.Title
        }
    }

    if ($mappingRoot.testPlanId) {
        $resultPayload.testPlan = @{
            id = "$($mappingRoot.testPlanId)"
        }
    }

    if ($mapped.AdoTestPointId) {
        $resultPayload.testPoint = @{
            id = "$($mapped.AdoTestPointId)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($trxResult.ErrorMessage)) {
        $resultPayload.errorMessage = $trxResult.ErrorMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($trxResult.StackTrace)) {
        $resultPayload.stackTrace = $trxResult.StackTrace
    }

    $adoResultsPayload += $resultPayload
}

$testRun = New-AdoTestRun `
    -Organization $adoOrg `
    -Project $adoProject `
    -Headers $headers `
    -Name $RunName `
    -ApiVersion $ApiVersion `
    -MappingRoot $mappingRoot

$runId = [int]$testRun.id

Write-Info "Created ADO test run ID: $runId"

$publishResponse = Add-AdoTestResults `
    -Organization $adoOrg `
    -Project $adoProject `
    -Headers $headers `
    -RunId $runId `
    -ResultsPayload $adoResultsPayload `
    -ApiVersion $ApiVersion

Complete-AdoTestRun `
    -Organization $adoOrg `
    -Project $adoProject `
    -Headers $headers `
    -RunId $runId `
    -ApiVersion $ApiVersion | Out-Null

Write-Host ""
Write-Host "========================================"
Write-Host "Publish Summary"
Write-Host "========================================"
Write-Host "ADO Test Run ID: $runId"
Write-Host "Mapped results published: $($adoResultsPayload.Count)"
Write-Host "Unmapped TRX results: $($unmappedResults.Count)"

if ($unmappedResults.Count -gt 0) {
    Write-Host ""
    Write-Host "Unmapped results:"
    foreach ($item in $unmappedResults) {
        Write-Host " - $($item.FullyQualifiedName)"
    }
}

Write-Host ""
Write-Host "Done."
