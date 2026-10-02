param([string]$Configuration = 'debug')
$ErrorActionPreference = 'Stop'
$cecRoot = Split-Path -Parent $PSScriptRoot
$cecScratch = Join-Path $cecRoot ('.build/gate-regression-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cecScratch -Force | Out-Null
$cecFailures = [Collections.Generic.List[string]]::new()

# Deliberately return an unrelated error whose filename contains "Escape".
# The safety gate must inspect the diagnostic message, not the path.
function swiftc {
    $cecFixture = @($args | Where-Object { $_ -like '*.swift' })[0]
    $cecName = [IO.Path]::GetFileNameWithoutExtension($cecFixture)
    $global:LASTEXITCODE = 1
    switch ($cecName) {
        'UnsafeReadPositive' { $global:LASTEXITCODE = 0 }
        'ArenaScopedPositive' { $global:LASTEXITCODE = 0 }
        'UnsafeReadRejected' { "$($cecFixture):1:1: error: unmarked unsafe expression [#StrictMemorySafety]" }
        'UnsafeStorageRejected' { "$($cecFixture):1:1: error: unmarked unsafe storage [#StrictMemorySafety]" }
        'ArenaEscapeRejected' { "$($cecFixture):1:1: error: unrelated syntax failure" }
        'ArenaMutationWhileBorrowedRejected' { "$($cecFixture):1:1: error: overlapping accesses to 'arena'" }
        default { throw "unexpected fixture: $cecName" }
    }
}
$cecRejectedDiagnostic = $false
try {
    # Keep synthetic diagnostics separate from the real compiler evidence.
    $cecFakeConfiguration = 'gate-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    & (Join-Path $PSScriptRoot 'cec_memory_safety_checks.ps1') -BinPath $cecScratch -Configuration $cecFakeConfiguration
} catch {
    if ($_.Exception.Message -notmatch 'Safety rejection not enforced: ArenaEscapeRejected') { throw }
    $cecRejectedDiagnostic = $true
}
if (-not $cecRejectedDiagnostic) { $cecFailures.Add('safety gate accepted an unrelated error through its filename') }
else { Write-Host 'PASS gate rejects unrelated diagnostic containing Escape in filename' }

Copy-Item -LiteralPath (Join-Path $cecRoot 'Sources') -Destination $cecScratch -Recurse
Copy-Item -LiteralPath (Join-Path $cecRoot 'Package.swift') -Destination $cecScratch
$cecOwnerPath = Join-Path $cecScratch 'Sources/CECClientCore/CECOwnership.swift'
[IO.File]::AppendAllText($cecOwnerPath, "`n@safe`nprivate struct UnreviewedSafeStorage { var address: UnsafePointer<Int>? }`n", [Text.UTF8Encoding]::new($false))
$cecRejectedAnnotation = $false
try { & (Join-Path $PSScriptRoot 'cec_source_policy.ps1') -ProjectRoot $cecScratch }
catch {
    if ($_.Exception.Message -notmatch 'Unreviewed safe declaration') { throw }
    $cecRejectedAnnotation = $true
}
if (-not $cecRejectedAnnotation) { $cecFailures.Add('source policy accepted an extra @safe in the permitted owner file') }
else { Write-Host 'PASS gate rejects extra @safe in the permitted owner file' }
# Restore the arena fixture before auditing the second exact safe declaration.
Copy-Item -LiteralPath (Join-Path $cecRoot 'Sources/CECClientCore/CECOwnership.swift') -Destination $cecOwnerPath
$cecControlPath = Join-Path $cecScratch 'Sources/CECClientCore/CECMetrics.swift'
[IO.File]::AppendAllText($cecControlPath, "`n@safe`nprivate struct UnreviewedSafeControl { var address: UnsafePointer<Int>? }`n", [Text.UTF8Encoding]::new($false))
$cecRejectedControl = $false
try { & (Join-Path $PSScriptRoot 'cec_source_policy.ps1') -ProjectRoot $cecScratch }
catch {
    if ($_.Exception.Message -notmatch 'Unreviewed safe control declaration') { throw }
    $cecRejectedControl = $true
}
if (-not $cecRejectedControl) { $cecFailures.Add('source policy accepted an extra @safe in the permitted control file') }
else { Write-Host 'PASS gate rejects extra @safe in the permitted control file' }
if ($cecFailures.Count -ne 0) { throw ($cecFailures -join '; ') }
