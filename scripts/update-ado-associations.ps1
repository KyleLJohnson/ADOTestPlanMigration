$mapping = Get-Content "./mapping/testcase-mapping.json" | ConvertFrom-Json

$org = $env:ADO_ORG
$project = $env:ADO_PROJECT
$pat = $env:ADO_PAT

$auth = [Convert]::

foreach ($suite in $mapping.testSuites) {
    foreach ($testCase in $suite.testCases) {

        $id = $testCase.adoTestCaseId
        $fqn = $testCase.automation.fullyQualifiedName

        Write-Host "Updating Test Case $id with FQN: $fqn"

        $body = @(
            @{
                op = "add"
                path = "/fields/Microsoft.VSTS.TCM.AutomatedTestName"
                value = $fqn
            }
        ) | ConvertTo-Json

        Invoke-RestMethod -Method Patch `
          -Uri "https://dev.azure.com/$org/$project/_apis/wit/workitems/$id?api-version=7.0" `
          -Headers @{
              Authorization = "Basic $auth"
          } `
          -ContentType "application/json-patch+json" `
          -Body $body
    }
}
