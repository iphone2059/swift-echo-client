param([Parameter(Mandatory)][string]$IRPath)
$ErrorActionPreference = 'Stop'
$ir = Get-Content -LiteralPath $IRPath -Raw
# A configuration value-witness copy can retain every stored reference while
# containing no direct swift_retain at its call site. Reject that copy anywhere.
if ($ir -match '\b(?:call|invoke)\b[^\r\n]*CECWorkerConfigurationVWOc') {
    throw 'configuration value-witness copy performs indirect ARC'
}
foreach ($name in @('beginAttempt','completeAttempt','cecProcessRIOResult','cecPostSend','cecDrainCompletions')) {
    $functions = [regex]::Matches($ir, '(?ms)^define [^\r\n]*' + $name + '[^\r\n]*\{.*?^\}')
    if ($functions.Count -eq 0) { throw "expected optimized $name function" }
    foreach ($function in $functions) {
        $arc = [regex]::Matches($function.Value, '\b(?:call|invoke)\b[^\r\n]*@swift_(?:retain|release)\b')
        if ($arc.Count -ne 0) { throw "$name contains $($arc.Count) ARC operations" }
        # Exported adapters may form one temporary borrow from a pinned pointer.
        # The internal per-attempt functions must forward the live configuration.
        if ($name -in @('beginAttempt','completeAttempt') -and
            $function.Value -match '@llvm\.memcpy[^\r\n]*i64 288,') {
            throw "$name still copies the complete 288-byte configuration"
        }
    }
    Write-Host "PASS optimized $name has no retain/release"
}
# Check the native dispatcher too, so moving ARC from a callee to its caller
# cannot make the two local body checks pass unnoticed (baseline has 14 sites).
$worker = [regex]::Matches($ir, '(?ms)^define [^\r\n]*(?:cecWorkerThread|cecRunWorker)[^\r\n]*\{.*?^\}')
$workerARC = 0
foreach ($function in $worker) {
    $workerARC += [regex]::Matches($function.Value, '\b(?:call|invoke)\b[^\r\n]*@swift_(?:retain|release)\b').Count
}
if ($worker.Count -eq 0 -or $workerARC -ne 0) { throw "worker dispatcher ARC regressed: $workerARC operations" }
Write-Host "PASS worker dispatcher ARC sites: $workerARC (baseline 14)"
