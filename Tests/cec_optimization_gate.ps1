param([Parameter(Mandatory)][string]$BinPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ir = Join-Path $root '.build/optimization-release.ll'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'Sources') -Filter '*.swift' -File | Where-Object { $_.Name -ne 'main.swift' }).FullName
& swiftc -emit-ir -O -whole-module-optimization -strict-memory-safety -warnings-as-errors -swift-version 6 -module-name CECClientCore -package-name swift_echo_client @sources -o $ir
if ($LASTEXITCODE -ne 0) { throw 'optimized IR compilation failed' }
$startInfo = [Diagnostics.ProcessStartInfo]::new((Join-Path $BinPath 'swift-echo-client-fault-driver.exe'))
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.ArgumentList.Add('config_layout')
$probe = [Diagnostics.Process]::Start($startInfo)
try {
    $stdout = $probe.StandardOutput.ReadToEndAsync()
    $stderr = $probe.StandardError.ReadToEndAsync()
    if (-not $probe.WaitForExit(5000)) { throw 'configuration layout probe timeout' }
    $layout = [regex]::Match($stdout.Result.Trim(), '^configuration_bytes=([0-9]+)$')
    if ($probe.ExitCode -ne 0 -or -not $layout.Success -or $stderr.Result.Trim().Length -ne 0) {
        throw "configuration layout probe failed: $($stdout.Result) $($stderr.Result)"
    }
    & (Join-Path $PSScriptRoot 'cec_optimization_checks.ps1') -IRPath $ir -ConfigurationBytes ([int]$layout.Groups[1].Value)
} finally {
    if (-not $probe.HasExited) {
        $probe.Kill($true)
        if (-not $probe.WaitForExit(5000)) { throw 'configuration layout probe cleanup timeout' }
    }
    $probe.Dispose()
}
