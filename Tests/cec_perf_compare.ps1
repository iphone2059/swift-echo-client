param([Parameter(Mandatory)][string]$SwiftClientPath,
      [Parameter(Mandatory)][string]$CppClientPath,
      [Parameter(Mandatory)][string]$ServerPath,
      [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.build/performance.json'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cec_test_support.ps1')
$results = [Collections.Generic.List[object]]::new()
foreach ($protocol in @('tcp','udp')) {
    $portPeer = [CECTestPeer]::new($protocol,'echo',4096); $port = $portPeer.Port; $portPeer.Dispose()
    $psi = [Diagnostics.ProcessStartInfo]::new($ServerPath)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    foreach ($arg in @('/p',$protocol,'/s',[string]$port,'/threads','1','/w','12','/q')) { $psi.ArgumentList.Add($arg) }
    $server = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $server.StandardOutput.ReadToEndAsync(); $stderr = $server.StandardError.ReadToEndAsync()
        Start-Sleep -Milliseconds 500
        if ($server.HasExited) { throw "server startup exit=$($server.ExitCode): $($stderr.Result)" }
        $args = @('127.0.0.1','/p',$protocol,'/r',[string]$port,'/n','20000','/z','1024','/c','4','/threads','1','/q','/stats')
        if ($protocol -eq 'tcp') { $args += @('/k','8') }
        foreach ($iteration in 1..3) {
            foreach ($client in @(@{Name='cpp';Path=$CppClientPath},@{Name='swift';Path=$SwiftClientPath})) {
                $r = Invoke-CECProcess $client.Path $args 10000
                if ($r.Code -ne 0 -or $r.Text -notmatch 'echoed=20000 corrupted=0 lost=0 network_errors=0') { throw "benchmark failure: $($client.Name) $($r.Text) $($r.ErrorText)" }
                $m = [regex]::Match($r.Text,'elapsed_ms=(\d+).*echo_per_sec=([\d.]+) MiB_per_sec=([\d.]+) p50_us~(\d+) p99_us~(\d+) p999_us~(\d+) max_us~(\d+)')
                if (-not $m.Success) { throw 'benchmark metrics missing' }
                $results.Add([pscustomobject]@{Protocol=$protocol;Client=$client.Name;Iteration=$iteration;ElapsedMilliseconds=[long]$m.Groups[1].Value;EchoPerSecond=[double]::Parse($m.Groups[2].Value,[Globalization.CultureInfo]::InvariantCulture);MiBPerSecond=[double]::Parse($m.Groups[3].Value,[Globalization.CultureInfo]::InvariantCulture);P50Microseconds=[long]$m.Groups[4].Value;P99Microseconds=[long]$m.Groups[5].Value;P999Microseconds=[long]$m.Groups[6].Value;MaxMicroseconds=[long]$m.Groups[7].Value;WallMilliseconds=$r.WallMilliseconds;CPUMilliseconds=$r.CPUMilliseconds;PeakWorkingSetBytes=$r.PeakWorkingSetBytes;Arguments=$args})
            }
        }
        if (-not $server.WaitForExit(13000)) { throw 'benchmark server stop timeout' }
        if ($server.ExitCode -ne 0) { throw "benchmark server exit=$($server.ExitCode): $($stderr.Result)" }
    } finally { if (-not $server.HasExited) { $server.Kill($true) }; $server.Dispose() }
}
$report = [pscustomobject]@{Date=[DateTimeOffset]::Now.ToString('o');SwiftVersion=(& swift --version | Out-String).Trim();Processor=$env:PROCESSOR_IDENTIFIER;LogicalProcessors=[Environment]::ProcessorCount;Notes='Release clients, same native C++ RIO server, alternating order, 3 samples per protocol; elapsed is client engine time, wall includes launch; loopback evidence without performance threshold.';Samples=$results}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath
$results | Format-Table Protocol,Client,Iteration,ElapsedMilliseconds,EchoPerSecond,MiBPerSecond,CPUMilliseconds,PeakWorkingSetBytes
