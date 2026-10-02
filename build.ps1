param([ValidateSet('debug','release')][string]$Configuration = 'debug')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & swift build -c $Configuration --product swift-echo-client
    if ($LASTEXITCODE -ne 0) { throw 'swift build failed' }
    & swift build -c $Configuration --product swift-echo-client-fault-driver
    if ($LASTEXITCODE -ne 0) { throw 'fault driver build failed' }
    # Swift Build's optimized Windows test runner omits the test DLL import.
    # Native SwiftPM links test objects directly; both configurations execute the same suites.
    & swift test -c $Configuration --build-system native 2>&1 | Tee-Object -Variable cecTestOutput
    if ($LASTEXITCODE -ne 0) { throw 'swift test failed' }
    $cecSummary = [regex]::Matches(($cecTestOutput -join "`n"), 'Test run with ([0-9]+) tests?\b[^\r\n]* passed')
    if ($cecSummary.Count -eq 0 -or [int]$cecSummary[$cecSummary.Count - 1].Groups[1].Value -eq 0) {
        throw 'Swift Testing did not execute any tests; verification failed'
    }
    $bin = (& swift build -c $Configuration --show-bin-path).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'product path failed' }
    foreach ($phase in @('features','owners')) {
        & pwsh -NoProfile -File tests/cec_ownership_compile_tests.ps1 -Configuration $Configuration -Phase $phase
        if ($LASTEXITCODE -ne 0) { throw "ownership $phase failed" }
    }
    & pwsh -NoProfile -File tests/cec_source_policy.ps1
    if ($LASTEXITCODE -ne 0) { throw 'source policy failed' }
    & pwsh -NoProfile -File tests/cec_memory_safety_checks.ps1 -BinPath $bin -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'memory safety gate failed' }
    & pwsh -NoProfile -File tests/cec_verification_gate_tests.ps1 -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'verification gate regressions failed' }
    if ($Configuration -eq 'release') {
        $cecIRPath = Join-Path $PSScriptRoot '.build/optimization-release.ll'
        $cecSources = (Get-ChildItem Sources/CECClientCore -Filter '*.swift').FullName
        & swiftc -emit-ir -O -whole-module-optimization -strict-memory-safety -warnings-as-errors -swift-version 6 -module-name CECClientCore -package-name swift_echo_client @cecSources -o $cecIRPath
        if ($LASTEXITCODE -ne 0) { throw 'optimized IR compilation failed' }
        & pwsh -NoProfile -File tests/cec_optimization_checks.ps1 -IRPath $cecIRPath
        if ($LASTEXITCODE -ne 0) { throw 'hot path ARC gate failed' }
    }
    $client = Join-Path $bin 'swift-echo-client.exe'
    $driver = Join-Path $bin 'swift-echo-client-fault-driver.exe'
    & pwsh -NoProfile -File tests/cec_fault_process_tests.ps1 -DriverPath $driver
    if ($LASTEXITCODE -ne 0) { throw 'fault processes failed' }
    & pwsh -NoProfile -File tests/cec_process_tests.ps1 -ClientPath $client
    if ($LASTEXITCODE -ne 0) { throw 'baseline process acceptance failed' }
    & pwsh -NoProfile -File tests/cec_extended_process_tests.ps1 -ClientPath $client -DriverPath $driver
    if ($LASTEXITCODE -ne 0) { throw 'extended process acceptance failed' }
    Write-Host "PASS $Configuration build and all checks: $client"
} finally { Pop-Location }
