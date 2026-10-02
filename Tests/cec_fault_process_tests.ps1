param([Parameter(Mandatory)][string]$DriverPath)
$ErrorActionPreference = 'Stop'
foreach ($mode in @('normal','notify_failure','corrupt_cq','notification_identity','outstanding_underflow','control_post_failure','arena_capacity','shutdown_stop_race','completion_range','completion_identity')) {
    $psi = [Diagnostics.ProcessStartInfo]::new($DriverPath)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.ArgumentList.Add($mode)
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $errorText = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) { $process.Kill($true); throw "$mode timeout" }
        $expected = if ($mode -in @('normal','shutdown_stop_race')) { 0 } else { 4 }
        if ($process.ExitCode -ne $expected) { throw "$mode exit=$($process.ExitCode): $($errorText.Result)" }
        if ($expected -eq 4 -and $errorText.Result -notmatch 'native_error=') { throw "$mode missing native diagnostic" }
        if ($mode -eq 'completion_range' -and $errorText.Result -notmatch 'client RIO RequestContext range') { throw 'completion range guard did not run' }
        if ($mode -eq 'completion_identity' -and $errorText.Result -notmatch 'client RIO RequestContext identity') { throw 'completion identity guard did not run' }
        Write-Host "PASS fault $mode"
    } finally { if (-not $process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}
