param([Parameter(Mandatory)][string]$DriverPath)
. (Join-Path $PSScriptRoot 'rio_fault_process_support.ps1')
$cases = @(
    @{ Mode='normal'; Exit=0 },
    @{ Mode='shutdown_stop_race'; Exit=0 },
    @{ Mode='notify_failure'; Exit=4; Stage='fault notify'; Error=5 },
    @{ Mode='corrupt_cq'; Exit=4; Stage='fault CQ'; Error=13 },
    @{ Mode='notification_identity'; Exit=4; Stage='fault identity'; Error=13 },
    @{ Mode='outstanding_underflow'; Exit=4; Stage='fault outstanding'; Error=13 },
    @{ Mode='control_post_failure'; Exit=4; Stage='fault control'; Error=6 },
    @{ Mode='arena_capacity'; Exit=4; Stage='client worker IOCP/CQ/arena capacity'; Error=8 },
    @{ Mode='completion_range'; Exit=4; Stage='client RIO RequestContext range'; Error=13 },
    @{ Mode='completion_identity'; Exit=4; Stage='client RIO RequestContext identity'; Error=13 },
    @{ Mode='worker_release_positive'; Exit=0; Output='(?m)^worker release positive\r?$' },
    @{ Mode='aggregate_deinit_positive'; Exit=0; Output='(?m)^aggregate deinit positive owners=3\r?$' },
    @{ Mode='worker_deinit'; Exit=4; Stage='client worker release precondition'; Error=996 },
    @{ Mode='transport_deinit'; Exit=4; Stage='client worker release precondition'; Error=996 },
    @{ Mode='resources_deinit'; Exit=4; Stage='client worker release precondition'; Error=996 },
    @{ Mode='worker_deinit_unjoined'; Exit=4; Stage='client worker release precondition'; Error=5023 },
    @{ Mode='timer_resolution_positive'; Exit=0; Output='(?m)^timer resolution positive begin=1 end=1 disabled=0\r?$' },
    @{ Mode='timer_resolution_failure'; Exit=4; Stage='timeBeginPeriod(client pacing)'; Error=97 },
    @{ Mode='worker_not_started'; Exit=4; Stage='client worker release precondition'; Error=996 },
    @{ Mode='worker_slot_ownership'; Exit=4; Stage='client worker release precondition'; Error=996 },
    @{ Mode='worker_release_order'; Exit=4; Stage='client worker release precondition'; Error=996 },
    @{ Mode='join_barrier_positive'; Exit=0; Output='(?m)^join barrier positive workers=2\r?$'; JoinMarkers=2 },
    @{ Mode='join_barrier_failure'; Exit=4; Stage='client worker release precondition'; Error=996; JoinMarkers=2 },
    @{ Mode='drain_rio_positive'; Exit=0; Output='(?m)^completion drained positive\r?$' },
    @{ Mode='missing_rio_completion'; Exit=4; Stage='client generation drain'; Error=1460 },
    @{ Mode='drain_connect_positive'; Exit=0; Output='(?m)^completion drained positive\r?$' },
    @{ Mode='missing_connect_completion'; Exit=4; Stage='client generation drain'; Error=1460 },
    @{ Mode='operation_positive'; Exit=0; Output='(?m)^operation ledger positive\r?$' },
    @{ Mode='send_extent_positive'; Exit=0; Output='(?m)^operation ledger positive\r?$' },
    @{ Mode='send_offset_underflow'; Exit=4; Stage='client completion exceeds posted range'; Error=13 },
    @{ Mode='stale_generation'; Exit=4; Stage='client completion generation'; Error=13 },
    @{ Mode='duplicate_operation'; Exit=4; Stage='client duplicate RIO completion'; Error=13 },
    @{ Mode='posted_extent'; Exit=4; Stage='client completion exceeds posted range'; Error=13 },
    @{ Mode='socket_identity'; Exit=4; Stage='client RIO SocketContext identity'; Error=13 }
)
foreach ($case in $cases) { $null = Assert-RioFaultCase -DriverPath $DriverPath -Case $case }
foreach ($hide in @($false, $true)) {
    $peer = [RioFaultPeer]::Listen()
    try {
        $case = if ($hide) {
            @{ Mode='e2e_missing_completion'; Exit=4; Stage='client generation drain'; Error=1460; Evidence='(?m)^e2e observed_cancelled_completion=(?:995|10053) withheld=1\r?$' }
        } else {
            @{ Mode='e2e_cancel_positive'; Exit=0; Output='(?m)^e2e cancelled_completions=[1-9][0-9]* withheld=0\r?$' }
        }
        $null = Assert-RioFaultCase -DriverPath $DriverPath -Case $case -Port $peer.Port
        if (-not $peer.Connected -or $peer.ReceivedBytes -le 0) { throw 'Client fault peer never observed a real connected send' }
    } finally { $peer.Dispose() }
}
