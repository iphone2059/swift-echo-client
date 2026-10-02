param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$sources = Get-ChildItem -LiteralPath (Join-Path $root 'Sources') -Recurse -File -Filter '*.swift'
$all = ($sources | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
if ($all.Contains([char]0)) { throw 'NUL bytes in Swift source' }
foreach ($rule in @(
    '\b(?:send|recv|sendto|recvfrom|WSASend|WSARecv|WSASendTo|WSARecvFrom)\s*\(',
    '@unchecked\s+Sendable',
    'FoundationNetworking|NWConnection|URLSession',
    'cpp-echo-client|cpp-echo-server|swift-echo-server',
    'disable-dynamic-exclusivity|enforce-exclusivity=unchecked'
    'import\s+Testing\b|@Test\b|\bcecExercise\w*\s*\('
)) { if ($all -match $rule) { throw "source policy violation: $rule" } }
if ($sources.Name -match 'Tests?\.swift$') { throw 'test source belongs under Tests, not Sources' }
foreach ($required in @('RIOReceive','RIOSend','ConnectEx','~Copyable','UniqueArray','MutableSpan','borrow','Atomic','cecWorkerMayRelease','cecRequireOutstanding')) {
    if (-not $all.Contains($required)) { throw "source policy missing: $required" }
}
$manifest = Get-Content -LiteralPath (Join-Path $root 'Package.swift') -Raw
if ($manifest -match '\.package\(' -or $manifest -match 'unsafeFlags') { throw 'external package or unchecked compiler flag' }
if ($manifest -notmatch 'swift-tools-version: 6.4' -or $manifest -notmatch 'swiftLanguageModes:\s*\[.v6\]') { throw 'Swift 6.4/v6 required' }
if ($manifest -notmatch 'path:\s*"Tests/CECFaultDriver"') { throw 'fault driver must be a separate target under Tests' }
if ([regex]::Matches($manifest, '\.strictMemorySafety\(\)').Count -ne 2 -or
    [regex]::Matches($manifest, '\.treatWarning\("StrictMemorySafety", as: \.error\)').Count -ne 2) {
    throw 'core and production executable require strict memory safety as errors'
}
# Exactly two reviewed owners abstract unsafe storage; no blanket safe exemption.
foreach ($source in $sources) {
    $text = Get-Content -LiteralPath $source.FullName -Raw
    if ($text -match '@safe' -and $source.Name -notin @('CECOwnership.swift','CECMetrics.swift')) { throw "Unreviewed @safe: $($source.Name)" }
    if ($source.Name -eq 'CECOwnership.swift' -and
        ([regex]::Matches($text, '@safe\b').Count -ne 1 -or
         [regex]::Matches($text, '@safe\s+package struct CECVirtualArenaOwner').Count -ne 1)) {
        throw 'Unreviewed safe declaration'
    }
    if ($source.Name -eq 'CECMetrics.swift' -and
        ([regex]::Matches($text, '@safe\b').Count -ne 1 -or
         [regex]::Matches($text, '@safe\s+package final class CECSharedControl').Count -ne 1)) {
        throw 'Unreviewed safe control declaration'
    }
}
Write-Host 'PASS standalone RIO/ownership source policy'
