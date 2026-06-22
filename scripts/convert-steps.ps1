$raw = Get-Content "./data/raw-ado-testcases.json" | ConvertFrom-Json

$result = @()

foreach ($test in $raw.value) {
    $steps = @()

    if ($test.stepsXml) {
        [xml]$xml = $test.stepsXml

        foreach ($step in $xml.steps.step) {
            $steps += @{
                action = $step.parameterizedString[0]
                expected = $step.parameterizedString[1]
            }
        }
    }

    $result += @{
        id = $test.id
        title = $test.name
        steps = $steps
    }
}

$result | ConvertTo-Json -Depth 10 | Out-File "./data/transformed-testcases.json"
