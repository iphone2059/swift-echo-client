param([Parameter(Mandatory)][string]$IRPath, [Parameter(Mandatory)][int]$ConfigurationBytes)
$ErrorActionPreference = 'Stop'
$ir = Get-Content -LiteralPath $IRPath -Raw
if ($ConfigurationBytes -le 0) { throw 'configuration layout probe must report a positive size' }
# A configuration value-witness copy can retain every stored reference while
# containing no direct swift_retain at its call site. Reject that copy anywhere.
if ($ir -match '\b(?:call|invoke)\b[^\r\n]*CECWorkerConfigurationVWOc') {
    throw 'configuration value-witness copy performs indirect ARC'
}
function Get-SwiftMethodPattern([string]$Owner, [string]$Method) {
    # Match a method's actual container and mangled identifier. In particular,
    # CECEngineSession.connectOverlapped cannot prove CECRioAdapter.connect.
    # Swift compresses the owner's last word when it repeats (CECWorkerCore ->
    # CECWorkerB0, CECEngineWorker -> CECEngineE0) and a generic owner carries its
    # generic arguments before the method identifier, so a non-generic V<length><name>
    # and a generic ...E<length><name> are both accepted.
    $stem = $Owner -replace '[A-Z][a-z0-9]*$', ''
    $compressed = [regex]::Escape($stem) + '[A-Z]0'
    return '(?:' + [regex]::Escape($Owner) + '|' + $compressed + ')[A-Za-z0-9_]*(?:V|E)' +
        $Method.Length + [regex]::Escape($Method)
}
$bodies = @([regex]::Matches($ir, '(?ms)^define [^\r\n]*\{.*?^\}'))
function Get-OptimizedBodies([string]$Pattern) {
    return @($bodies | Where-Object { ($_.Value -split '\r?\n', 2)[0] -match $Pattern })
}
function Assert-OptimizedBodies([string]$Name, [object[]]$Functions) {
    if ($Functions.Count -eq 0) { throw "expected optimized $Name function" }
    foreach ($function in $Functions) {
        $arc = [regex]::Matches($function.Value, '\b(?:call|invoke)\b[^\r\n]*@swift_(?:retain|release|bridgeObjectRetain|bridgeObjectRelease)\b')
        if ($arc.Count -ne 0) { throw "$Name contains $($arc.Count) ARC operations" }
        if ($function.Value -match ('@llvm\.memcpy[^\r\n]*i64 ' + $ConfigurationBytes + ',')) { throw "$Name copies the complete $ConfigurationBytes-byte configuration" }
    }
    Write-Host "PASS optimized ${Name}: $($Functions.Count) actual definitions, no ARC/full configuration copy"
}
$paths = @(
    @{ Owner='CECWorkerCore'; Method='beginAttempt'; Parents=@('CECWorkerCoreV7onEvent','CECWorkerCoreV5start','CECWorkerCoreV4poll') },
    @{ Owner='CECWorkerCore'; Method='settleAttempt'; Parents=@('CECWorkerCoreV7onEvent') },
    @{ Owner='CECWorkerCore'; Method='onEvent' },
    @{ Owner='CECWorkerCore'; Method='start' },
    @{ Owner='CECWorkerCore'; Method='poll' },
    @{ Owner='CECWorkerRuntime'; Method='handleCompletion' },
    @{ Owner='CECWorkerRuntime'; Method='deliver' },
    @{ Owner='CECWorkerRuntime'; Method='dispatch' },
    @{ Owner='CECWorkerRuntime'; Method='beginStop' },
    @{ Owner='CECWorkerRuntime'; Method='start' },
    @{ Owner='CECWorkerRuntime'; Method='poll' },
    @{ Owner='CECRioAdapter'; Method='retireRio' },
    @{ Owner='CECRioAdapter'; Method='retireConnect' },
    @{ Owner='CECRioAdapter'; Method='sendTail'; Parents=@('CECRioAdapterV4send','CECRioAdapterV9retireRio') },
    @{ Owner='CECRioAdapter'; Method='maybeArm' },
    @{ Owner='CECRioAdapter'; Method='compareReceive' },
    @{ Owner='CECRioAdapter'; Method='connect' },
    @{ Owner='CECRioAdapter'; Method='receive' },
    @{ Owner='CECRioAdapter'; Method='send' },
    @{ Owner=''; Method='cecProcessRIOResult' },
    @{ Owner=''; Method='cecPostSend' },
    @{ Owner=''; Method='cecDrainCompletions' },
    @{ Owner=''; Method='drainBatch'; Parents=@('cecDrainCompletions','cecRunWorker') },
    @{ Owner=''; Method='consumePacket'; Parents=@('cecRunWorker') }
)
foreach ($path in $paths) {
    $pattern = if ($path.Owner) { Get-SwiftMethodPattern $path.Owner $path.Method } else { $path.Method.Length.ToString() + [regex]::Escape($path.Method) }
    $functions = @(Get-OptimizedBodies $pattern)
    if ($functions.Count -ne 0) { Assert-OptimizedBodies "$($path.Owner).$($path.Method)" $functions }
    elseif ($path.ContainsKey('Parents')) {
        # Private helpers may disappear under WMO. Inspect every production
        # parent that can contain their inlined body, and require each to exist.
        foreach ($parent in $path.Parents) { Assert-OptimizedBodies "$($path.Method) inlined in $parent" @(Get-OptimizedBodies $parent) }
    } else { throw "expected actual optimized method $($path.Owner).$($path.Method)" }
}
# Check the native dispatcher too, so moving ARC from a callee to its caller
# cannot make the two local body checks pass unnoticed (baseline has 14 sites).
$worker = [regex]::Matches($ir, '(?ms)^define [^\r\n]*(?:cecWorkerThread|cecRunWorker)[^\r\n]*\{.*?^\}')
$workerARC = 0
foreach ($function in $worker) {
    $workerARC += [regex]::Matches($function.Value, '\b(?:call|invoke)\b[^\r\n]*@swift_(?:retain|release|bridgeObjectRetain|bridgeObjectRelease)\b').Count
}
if ($worker.Count -eq 0 -or $workerARC -ne 0) { throw "worker dispatcher ARC regressed: $workerARC operations" }
Write-Host "PASS worker dispatcher ARC sites: $workerARC (baseline 14)"
