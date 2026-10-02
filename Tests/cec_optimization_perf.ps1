param([Parameter(Mandatory)][string]$BaselineClientPath,
      [Parameter(Mandatory)][string]$ClientPath,
      [Parameter(Mandatory)][string]$ServerPath,
      [ValidateRange(3,30)][int]$Seconds = 5,
      [ValidateRange(3,9)][int]$Iterations = 3,
      [ValidateRange(1,1048576)][int]$SessionCount = 4,
      [ValidateRange(1,64)][int]$WorkerCount = 1,
      [ValidateRange(1,65507)][int]$PayloadBytes = 1024,
      [ValidateRange(1,1048576)][int]$TCPDepth = 8,
      [ValidateRange(1,64)][int]$ServerWorkers = 1,
      [ValidateSet('both','tcp','udp')][string]$Transport = 'both',
      [uint64]$EchoCount = 0,
      [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
if ([long]$PayloadBytes * $TCPDepth -gt 67108864) { throw 'TCP batch exceeds 64 MiB' }
. (Join-Path $PSScriptRoot 'cec_test_support.ps1')
$cecResults = [Collections.Generic.List[object]]::new()
$cecClients = @(@{Name='before';Path=$BaselineClientPath},@{Name='after';Path=$ClientPath})
foreach ($cecProtocol in $(if ($Transport -eq 'both') { @('tcp','udp') } else { @($Transport) })) {
    $cecPortPeer = [CECTestPeer]::new($cecProtocol,'echo',4096)
    $cecPort = $cecPortPeer.Port; $cecPortPeer.Dispose()
    $cecServerSeconds = if ($EchoCount -eq 0) { 2 * $Iterations * $Seconds + 8 } else { 0 }
    $cecInfo = [Diagnostics.ProcessStartInfo]::new($ServerPath)
    $cecInfo.UseShellExecute = $false; $cecInfo.CreateNoWindow = $true
    $cecInfo.RedirectStandardOutput = $true; $cecInfo.RedirectStandardError = $true
    $cecServerArgs = @('/p',$cecProtocol,'/s',[string]$cecPort,'/threads',[string]$ServerWorkers,'/q')
    if ($EchoCount -eq 0) { $cecServerArgs += @('/w',[string]$cecServerSeconds) }
    foreach ($cecArg in $cecServerArgs) { $cecInfo.ArgumentList.Add($cecArg) }
    $cecServer = [Diagnostics.Process]::Start($cecInfo)
    try {
        $cecServerOut = $cecServer.StandardOutput.ReadToEndAsync()
        $cecServerError = $cecServer.StandardError.ReadToEndAsync()
        Start-Sleep -Milliseconds 500
        if ($cecServer.HasExited) { throw "server startup exit=$($cecServer.ExitCode): $($cecServerError.Result)" }
        $cecCommon = @('127.0.0.1','/p',$cecProtocol,'/r',[string]$cecPort,'/z',[string]$PayloadBytes,
            '/c',[string]$SessionCount,'/threads',[string]$WorkerCount,'/q','/stats')
        if ($cecProtocol -eq 'tcp') { $cecCommon += @('/k',[string]$TCPDepth) }
        foreach ($cecClient in $cecClients) {
            $cecWarm = Invoke-CECProcess $cecClient.Path ($cecCommon + @('/n','10000')) 10000
            if ($cecWarm.Code -ne 0 -or $cecWarm.Text -notmatch 'echoed=10000 corrupted=0 lost=0 network_errors=0') { throw 'warmup failed' }
        }
        foreach ($cecIteration in 1..$Iterations) {
            $cecOrder = if ($cecIteration % 2 -eq 1) { @(0,1) } else { @(1,0) }
            foreach ($cecIndex in $cecOrder) {
                $cecClient = $cecClients[$cecIndex]
                $cecArgs = if ($EchoCount -eq 0) { $cecCommon + @('/n','0','/w',[string]$Seconds) } else { $cecCommon + @('/n',[string]$EchoCount) }
                $cecTimeout = if ($EchoCount -eq 0) { ($Seconds+3)*1000 } else { 60000 }
                $cecRun = Invoke-CECProcess $cecClient.Path $cecArgs $cecTimeout
                if ($cecRun.Code -ne 0 -or $cecRun.Text -notmatch 'corrupted=0 lost=0 network_errors=0') {
                    throw "benchmark failure: $($cecClient.Name) $($cecRun.Text) $($cecRun.ErrorText)"
                }
                $cecMatch = [regex]::Match($cecRun.Text,'elapsed_ms=(\d+).*echoed=(\d+).*echo_per_sec=([\d.]+).*p99_us~(\d+)')
                if (-not $cecMatch.Success -or [long]$cecMatch.Groups[2].Value -eq 0) { throw 'benchmark metrics missing' }
                if ($EchoCount -eq 0 -and [long]$cecMatch.Groups[1].Value -lt $Seconds*1000) { throw 'benchmark duration too short' }
                if ($EchoCount -ne 0 -and [uint64]$cecMatch.Groups[2].Value -ne $EchoCount) { throw 'benchmark finite quota mismatch' }
                $cecResults.Add([pscustomobject]@{
                    Protocol=$cecProtocol;Client=$cecClient.Name;Iteration=$cecIteration
                    ElapsedMilliseconds=[long]$cecMatch.Groups[1].Value;Echoed=[long]$cecMatch.Groups[2].Value
                    EchoPerSecond=[double]::Parse($cecMatch.Groups[3].Value,[Globalization.CultureInfo]::InvariantCulture)
                    P99Microseconds=[long]$cecMatch.Groups[4].Value
                    WallMilliseconds=$cecRun.WallMilliseconds;CPUMilliseconds=$cecRun.CPUMilliseconds
                    CPUMillisecondsPerMillionEchoes=$cecRun.CPUMilliseconds*1000000/[long]$cecMatch.Groups[2].Value
                    PeakWorkingSetBytes=$cecRun.PeakWorkingSetBytes;Arguments=$cecArgs
                })
                Write-Host "Measured $cecProtocol $($cecClient.Name) round ${cecIteration}: $($cecMatch.Groups[3].Value) echo/s"
            }
        }
        if ($EchoCount -eq 0) {
            if (-not $cecServer.WaitForExit(10000) -or $cecServer.ExitCode -ne 0) { throw 'benchmark server stop failed' }
        } elseif ($cecServer.HasExited) { throw 'finite benchmark server exited early' }
    } finally { if (-not $cecServer.HasExited) { $cecServer.Kill($true) }; $cecServer.Dispose() }
}
$cecReport = [pscustomobject]@{
    Date=[DateTimeOffset]::Now.ToString('o');SwiftVersion=(& swift --version | Out-String).Trim()
    Processor=$env:PROCESSOR_IDENTIFIER;LogicalProcessors=[Environment]::ProcessorCount
    BeforeSHA256=(Get-FileHash -LiteralPath $BaselineClientPath).Hash
    AfterSHA256=(Get-FileHash -LiteralPath $ClientPath).Hash
    ServerSHA256=(Get-FileHash -LiteralPath $ServerPath).Hash
    Workload=[pscustomobject]@{Sessions=$SessionCount;Workers=$WorkerCount;PayloadBytes=$PayloadBytes;TCPDepth=$TCPDepth;ServerWorkers=$ServerWorkers;Seconds=$(if ($EchoCount -eq 0) {$Seconds} else {$null});EchoCount=$EchoCount;Transport=$Transport;Iterations=$Iterations}
    Notes='Release before/after; same native RIO server; warmup excluded; alternating AB/BA ordering; whole-process CPU per completed echo; latency includes completion processing and payload verification; loopback results without performance threshold. EchoCount > 0 uses the same finite quota for both clients, a 60 s timeout, and terminates the benchmark server only after all clients complete; Seconds applies only to timed mode.'
    Samples=$cecResults
}
$cecReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath
$cecResults | Format-Table Protocol,Client,Iteration,EchoPerSecond,CPUMillisecondsPerMillionEchoes,P99Microseconds
