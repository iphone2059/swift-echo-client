param(
    [ValidateSet('debug', 'release')][string] $Configuration = 'debug',
    [ValidateSet('features', 'owners')][string] $Phase = 'features'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cecRoot = Split-Path $PSScriptRoot
$cecIdentity = (Split-Path $cecRoot -Leaf).ToLowerInvariant() -replace '[^a-z0-9_]', '_'
$cecBin = (& swift build --package-path $cecRoot -c $Configuration --show-bin-path).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve Swift product directory' }
$cecScratch = Join-Path $cecRoot ".build/ownership-$Configuration"
New-Item -ItemType Directory -Path $cecScratch -Force | Out-Null
$cecCases = if ($Phase -eq 'features') {
    @(@('FeaturesPositive', $true), @('FeaturesCopyRejected', $false))
} else {
    @(@('OwnersPositive', $true), @('OwnersCopyRejected', $false),
      @('OwnersUseAfterConsumeRejected', $false), @('BorrowedOwnerDestroyedRejected', $false),
      @('SpanEscapeRejected', $false), @('ConfigurationCopyRejected', $false))
}
foreach ($cecCase in $cecCases) {
    $cecName = $cecCase[0]
    $cecFixture = Join-Path $PSScriptRoot "ownership/$cecName.swift"
    $cecLog = Join-Path $cecScratch "$cecName.log"
    & swiftc -swift-version 6 -package-name $cecIdentity -parse-as-library -c -I $cecBin $cecFixture -o (Join-Path $cecScratch "$cecName.obj") *> $cecLog
    $cecCode = $LASTEXITCODE
    $cecOutput = Get-Content -LiteralPath $cecLog -Raw
    $cecDiagnostics = (($cecOutput -split "`n") | ForEach-Object { if ($_ -match 'error:\s*(.+)') { $Matches[1] } }) -join "`n"
    if ($cecCase[1]) {
        if ($cecCode -ne 0) { throw "Positive ownership fixture failed: $cecName`n$cecOutput" }
    } elseif ($cecCode -eq 0 -or $cecDiagnostics -notmatch '(?i)noncopyable|consum|borrow|lifetime|escap') {
        throw "Expected ownership diagnostic missing: $cecName`n$cecOutput"
    }
    Write-Host "PASS ownership $cecName"
}
