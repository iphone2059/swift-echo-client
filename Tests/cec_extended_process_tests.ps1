param([Parameter(Mandatory)][string]$ClientPath, [string]$DriverPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cec_test_support.ps1')
function Assert-Result($Result, [int]$Code, [string[]]$Patterns) {
    if ($Result.Code -ne $Code) { throw "exit $($Result.Code), expected ${Code}: $($Result.Text) $($Result.ErrorText)" }
    foreach ($pattern in $Patterns) { if ($Result.Text -notmatch $pattern) { throw "missing ${pattern}: $($Result.Text)" } }
}
foreach ($scenario in @('multithread','reconnect','corruptStop','pacing')) {
    $mode = switch ($scenario) { multithread { 'fragment' } reconnect { 'reconnect' } corruptStop { 'corruptHold' } pacing { 'echo' } }
    $peer = [CECTestPeer]::new('tcp',$mode,4096)
    try {
        $args = @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,'/z','4096','/q','/stats')
        switch ($scenario) {
            # /n is a per-session quota: eight sessions of 37 echoes are 296 in total.
            multithread { $args += @('/n','37','/k','8','/c','8','/threads','3'); $code = 0; $patterns = @('echoed=296 ','corrupted=0 ','lost=0 ','network_errors=0 ') }
            reconnect { $args += @('/n','3','/rc','0'); $code = 3; $patterns = @('echoed=1 ','lost=2 ','network_errors=2 ') }
            corruptStop { $args += @('/n','0','/w','1','/t','30'); $code = 3; $patterns = @('corrupted=1 ','lost=0 ') }
            pacing { $args += @('/n','3','/i','30'); $code = 0; $patterns = @('echoed=3 ','lost=0 ') }
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Assert-Result (Invoke-CECProcess $ClientPath $args 5000) $code $patterns
        if ($scenario -eq 'reconnect' -and $peer.Accepts -ne 3) { throw "reconnect accepts=$($peer.Accepts)" }
        if ($scenario -eq 'pacing' -and $timer.ElapsedMilliseconds -lt 80) { throw 'pacing interval ignored' }
        Write-Host "PASS $scenario"
    } finally { $peer.Dispose() }
}
foreach ($literal in @('中文 😀','spaces and "quotes"','trailing slash \')) {
    $peer = [CECTestPeer]::new('udp','echo',4096)
    try {
        Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','udp','/r',[string]$peer.Port,'/n','1','/d',$literal,'/q','/stats')) 0 @('echoed=1 ')
        $payload = $peer.Payloads.ToArray()[0]
        if ([Convert]::ToHexString($payload) -ne [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($literal))) { throw 'wide argument bytes differ' }
    } finally { $peer.Dispose() }
}
Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/d',([string][char]0xD800))) 1 @()
Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','udp','/d',('中'*22000))) 1 @()
Write-Host 'PASS wide arguments and payload limits'
$peer = [CECTestPeer]::new('tcp','hold',4096)
try {
    $result = Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,'/n','0','/z','4096','/w','2','/t','30','/q','/report','1') 5000
    Assert-Result $result 0 @('report elapsed_ms=','echo_per_sec=\d+\.\d{2} MiB_per_sec=\d+\.\d{2}')
    if ($result.Text -match 'final ') { throw 'quiet without stats printed final' }
    Write-Host 'PASS periodic quiet metrics'
} finally { $peer.Dispose() }
$peer = [CECTestPeer]::new('tcp','echo',4096); $closedPort = $peer.Port; $peer.Dispose()
Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$closedPort,'/n','0','/q','/stats')) 2 @('network_errors=1 ')
Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$closedPort,'/n','1','/q','/stats')) 3 @('lost=1 ')
# One attempt is one receive plus one send, so 33 sessions in one shard need 66 queue entries and
# the reference rejects that while parsing the arguments. The diagnostic is on stderr.
$cq = Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/c','33','/threads','1','/cq','64','/z','1','/stats')
Assert-Result $cq 1 @()
if ($cq.ErrorText -notmatch 'cq-capacity') { throw "missing cq-capacity: $($cq.ErrorText)" }
Write-Host 'PASS connection refusal and CQ capacity failure'
foreach ($count in @(1,10003)) {
    $peer = [CECTestPeer]::new('tcp','echo',4096)
    try {
        # The quota is per session, so 64 sessions of $count echoes complete $count * 64 in total.
        Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,
            '/n',[string]$count,'/k','8','/z','64','/c','64','/threads','64','/q','/stats') 10000) 0 @(
            "echoed=$($count * 64) ", 'corrupted=0 ', 'lost=0 ', 'network_errors=0 ')
    } finally { $peer.Dispose() }
}
Write-Host 'PASS 64 workers, early finishes and exact finite quota'
$peer = [CECTestPeer]::new('tcp','reconnect',4096)
try {
    Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,
        '/n','0','/z','4096','/q','/stats') 5000) 3 @('lost=1 ', 'network_errors=1 ')
    Write-Host 'PASS unlimited noncontrolled failure accounting'
} finally { $peer.Dispose() }
foreach ($threads in @(1,4)) {
    $peer = [CECTestPeer]::new('tcp','echo',4096)
    try {
        # 256 KiB batch: the reference budget is two batches per session whatever the worker split
        # is, so the same limit is required for one worker and for four.
        $memory = 2097152
        $result = Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,
            '/n','37','/k','4','/z','65536','/c','4','/threads',[string]$threads,
            '/memory',[string]$memory,'/q','/stats')
        Assert-Result $result 0 @('echoed=148 ', 'corrupted=0 ', 'lost=0 ')
        Assert-Result (Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,
            '/n','1','/k','4','/z','65536','/c','4','/threads',[string]$threads,
            '/memory',[string]($memory-1),'/q','/stats')) 1 @()
    } finally { $peer.Dispose() }
}
Write-Host 'PASS shared storage capacity and final partial batch'
$peer = [CECTestPeer]::new('tcp','echo',4096)
try {
    $result = Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,
        '/n','0','/z','64','/c','64','/threads','64','/w','2','/report','1','/q','/stats') 10000
    Assert-Result $result 0 @('report elapsed_ms=', 'final elapsed_ms=', 'corrupted=0 ', 'lost=0 ', 'network_errors=0 ')
    $previous = 0L
    foreach ($line in $result.Text -split "\r?\n") {
        $match = [regex]::Match($line,'^(?:report|final) .*echoed=(\d+) ')
        if ($match.Success) {
            $value = [long]$match.Groups[1].Value
            if ($value -lt $previous) { throw 'published metrics went backwards' }
            $previous = $value
        }
    }
    if ($previous -eq 0) { throw 'concurrent report made no progress' }
    Write-Host 'PASS concurrent reports and run deadline with 64 workers'
} finally { $peer.Dispose() }
$peer = [CECTestPeer]::new('tcp','echo',64)
try {
    $result = Invoke-CECProcess $ClientPath @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,
        '/n','20','/z','64','/i','1','/q','/stats') 5000
    Assert-Result $result 0 @('echoed=20 ', 'corrupted=0 ', 'lost=0 ', 'network_errors=0 ')
    $elapsed = [regex]::Match($result.Text,'final elapsed_ms=(\d+)')
    if (-not $elapsed.Success -or [long]$elapsed.Groups[1].Value -lt 19) { throw '1 ms pacing ignored' }
    Write-Host 'PASS 1 ms pacing'
} finally { $peer.Dispose() }
foreach ($timeout in @('1','4294967295')) {
    $peer = [CECTestPeer]::new('tcp','hold',64)
    try {
        $args = @('127.0.0.1','/p','tcp','/r',[string]$peer.Port,'/n','1','/z','64',
            '/t',$timeout,'/q','/stats')
        if ($timeout -eq '1') {
            $result = Invoke-CECProcess $ClientPath $args 5000
            Assert-Result $result 3 @('echoed=0 ', 'lost=1 ', 'network_errors=1 ')
            $elapsed = [regex]::Match($result.Text,'final elapsed_ms=(\d+)')
            if (-not $elapsed.Success -or [long]$elapsed.Groups[1].Value -lt 1000) { throw 'request timeout fired early' }
        } else {
            Assert-Result (Invoke-CECProcess $ClientPath ($args + @('/w','1')) 5000) 0 @(
                'echoed=0 ', 'lost=0 ', 'network_errors=0 ')
        }
    } finally { $peer.Dispose() }
}
Write-Host 'PASS request timeout and maximum timeout controlled drain'
if ($DriverPath) {
    $peer = [CECTestPeer]::new('tcp','echoThenHold',4096)
    try {
        Assert-Result (Invoke-CECProcess $DriverPath @('partial_startup',[string]$peer.Port)) 4 @('partial startup drained')
        Write-Host 'PASS partial startup failure drain'
    } finally { $peer.Dispose() }
    $eventName = 'Local\cec_console_' + [Guid]::NewGuid().ToString('N')
    $event = [Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$eventName)
    $peer = [CECTestPeer]::new('tcp','hold',4096,$eventName)
    try {
        Assert-Result (Invoke-CECProcess $DriverPath @('console_stop',$ClientPath,[string]$peer.Port,$eventName)) 0 @()
        Write-Host 'PASS console Ctrl+Break drain'
    } finally { $peer.Dispose(); $event.Dispose() }
}
