param([Parameter(Mandatory)][string]$BinPath, [string]$Configuration = 'debug')
$ErrorActionPreference = 'Stop'
$cecRoot = Split-Path -Parent $PSScriptRoot
$cecIdentity = (Split-Path $cecRoot -Leaf).ToLowerInvariant() -replace '[^a-z0-9_]', '_'
$cecScratch = Join-Path $cecRoot ".build/safety-$Configuration"
New-Item -ItemType Directory -Path $cecScratch -Force | Out-Null
$cecCases = @(
  @('UnsafeReadPositive', $true, ''),
  @('ArenaScopedPositive', $true, ''),
  @('UnsafeReadRejected', $false, 'StrictMemorySafety'),
  @('UnsafeStorageRejected', $false, 'StrictMemorySafety'),
  @('ArenaEscapeRejected', $false, "requires that 'Span<UInt8>' conform to 'Escapable'"),
  @('ArenaMutationWhileBorrowedRejected', $false, 'overlapping accesses|exclusive access'))
foreach ($cecCase in $cecCases) {
  $cecName = $cecCase[0]
  $cecLog = Join-Path $cecScratch "$cecName.log"
  & swiftc -swift-version 6 -strict-memory-safety -warnings-as-errors -package-name $cecIdentity -parse-as-library -c -I $BinPath (Join-Path $PSScriptRoot "safety/$cecName.swift") -o (Join-Path $cecScratch "$cecName.obj") *> $cecLog
  $cecCode = $LASTEXITCODE
  $cecOutput = Get-Content -LiteralPath $cecLog -Raw
  $cecDiagnostics = (($cecOutput -split "`n") | ForEach-Object {
      if ($_ -match 'error:\s*(.+)') { $Matches[1] }
  }) -join "`n"
  if ($cecCase[1]) {
    if ($cecCode -ne 0) { throw "Positive safety fixture failed: $cecName`n$cecOutput" }
  } elseif ($cecCode -eq 0 -or $cecDiagnostics -notmatch $cecCase[2]) {
    throw "Safety rejection not enforced: $cecName`n$cecOutput"
  }
  Write-Host "PASS memory safety $cecName"
}
