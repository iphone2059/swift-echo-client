# Swift Client resumed source review — 2026-10-14

Owner: /root/resume_client. Historical review base: d8a847ab5e7dc55fbea636a030e71f4b16eda25a (main). Root verified clean main/origin before dispatch; this owner independently observed main...origin/main = 0 0 and clean status before source changes. No branch or worktree created. Read root AGENTS.md, the complete remaining-alignment specification and v2.0 spec. Changes are limited to verified Client source/fixture/doc gaps; root owns all PS1/CMake/tools changes.

**Evidence level: S0/S1 static source review only. No formatter, compiler, Swift probe, executable, unit test, gate, commit or push was run by this owner.** Historical REVIEW_CHECKPOINT_2026-10-14.md and client-report.md were preserved unchanged. Functional, IR and formal-performance conclusions remain pending.

## Verified changes

### SW-C-02: operation ownership and posted extent precede subtraction

At the base snapshot, engine.swift retireRio computed sendPostedBytes - sendOffset before checking sendOutstanding. These are signed Int fields: a corrupted offset of Int.min can overflow that subtraction before cecFailFast emits its named invariant. A duplicate completion in the unowned direction could therefore trap instead of reporting duplicate ownership.

Current engine.swift:397 first checks the matching operation flag. Lines 404–418 check positive original posted length, its configured maximum, and 0 <= sendOffset < sendPostedBytes before subtraction; only then do BytesTransferred and counters retire. SendTail:376 also rejects negative offsets before UInt32 conversion. Completion stage/error remains client completion exceeds posted range / 13; duplicate stage remains client duplicate RIO completion / 13. Normal remaining-byte arithmetic and repost order are unchanged.

Reference evidence:

- C++ cec_engine.cpp:505–518 checks operation_outstanding and posted RIO_BUF length before clearing flags/counters.
- Rust engine.rs:1398–1416 validates the send flag then uses checked_sub(send_offset), reporting an invariant on invalid offset before retirement.
- Zig engine.zig retireRio (base:950–957; current:960 onward) checks send_outstanding == 1, nonzero posted length and send_offset < send_posted_bytes before subtraction. Receive validates nonzero posted length too.

Focused existing-driver extensions, not executed:

- send_offset_underflow: original length 2, owned Send and offset Int.min; expected exit 4 + client completion exceeds posted range + native_error=13.
- send_extent_positive: original length 2, offset 1, final completion length 1; expected exit 0 + operation ledger positive. Proves a legitimate remaining tail passes the new guard and retires the closing generation.
- duplicate_operation: now also sets corrupt unused Send offset Int.min; still requires the existing duplicate diagnostic, proving ownership is checked before unused-direction arithmetic.
- Existing partialSendAndUDPShort, ordered send/receive, cancellation and posted_extent fixtures remain unchanged in their assertions.

### SW-C-03: failed finite quota balances attempted and lost

The base coordinator added finite unclaimed echoes to final.lost alone. Displayed attempted is final.claimed, so a failed run could print attempted < echoed + corrupted + lost + cancelled even with pending=0.

Current metrics.swift:68 accountUnclaimed adds the same unclaimed count to both joined aggregate claimed/attempted and lost. engine.swift:958 calls it only after the existing raw Session ledger guard; Session claims and quotas do not change. Controlled Stop still adds nothing. Classification remains lost/corrupted=exit3, fatal=exit4.

All three references agree:

- C++ cec_engine.cpp:986 displays claimed + terminal_unclaimed, and :1167 increments terminal_unclaimed alongside lost.
- Rust engine.rs:579–587 adds unclaimed to lost and attempted after all Join/release checks.
- Zig engine.zig (base:324–327; current:334–337) adds unclaimed to lost and attempted.

Added one focused pure regression with an independently specified ledger: requested 10, claimed 4, echoed 2, lost 2 becomes attempted 10/echoed 2/lost 8; controlled Stop with 2 echoed/2 cancelled stays attempted 4/lost0. Both require attempted == terminalCount and pending0. No existing assertion was weakened.

### CL-02b: CEC_DIAG_FILE snapshot support

Current metrics.swift:3–13 declares POD CECNotificationSnapshot and exact shared row rendering. native.swift:220–252 adds a noncopyable diagnostic file owner using the existing CECHandleOwner. It reads at most 512 WCHAR units with GetEnvironmentVariableW, accepts a nonempty path <512 units, opens GENERIC_WRITE/FILE_SHARE_READ/CREATE_ALWAYS/FILE_ATTRIBUTE_NORMAL, writes UTF-8 ASCII with LF and checks WriteFile byte count. Oversized rows follow the reference 192-byte including NUL limit. Open/write failures are silent and never change production output or result.

engine.swift:948–954 joins/checks every worker, merges final statistics, then reads/writes started-worker notification snapshots before cecDestroyWorker clears residual notification arms. Never-started workers are omitted; IDs use their original zero-based workerIndex. No hot-path allocation, dynamic dispatch or extra per-completion work was introduced.

Exact row:

`role=client protocol=tcp|udp worker=N notify_arms=N notify_deliveries=N notify_gap=N timeout_wakeups_while_outstanding=N` + LF.

C++ cec_engine_internal.cpp:80–134 and Rust engine.rs:19–34/native.rs:202–262 establish schema, silent failure, path/flags and saturated gap behavior. C++ cec_engine.cpp:1143–1156 captures after collective Join/check and before destruction; Rust returns native owner/counters to the join coordinator and verifies every owner before release (engine.rs:538–568). C++/Rust write their already captured rows later; Swift writes joined snapshots before destruction, preserving the same values and exit behavior. The root/reference owner is adding corresponding Zig Client support independently.

Added exact TCP/UDP row assertions in CECMetricsTests. The common binary verifier must exercise real files with notify-diagnostics enabled; static schema tests do not claim runtime acceptance. Root owns features.txt and verifier wiring.

## SW-C-03 six-boundary audit

| Boundary | Swift source evidence and result | Reference correspondence |
| --- | --- | --- |
| ConnectEx sync accepted / ERROR_IO_PENDING | engine.swift:286–339 increments generation only with Slot outstanding0; key encodes original generation; connectOutstanding is rolled back on immediate non-997 rejection; totalOutstanding increments only after provider acceptance. consumePacket validates original index/generation/OVERLAPPED before retireConnect:444. | C++ cec_engine.cpp:385–436 and :582–605; Rust native ConnectEx owner and transport connect/retire_into; Zig RioAdapter connect/retireConnect. Sync success and 997 both await real IOCP completion. |
| Send/Receive simultaneously outstanding | engine.swift:349–366 and :374–443 maintain independent flags; retireRio checks encoded operation, Slot/socket identity and generation before matching flag/count retirement. Runtime receives an already-accounted Completion. Core internal.swift:260–309 settles only corresponding business flag. | C++ cec_engine.cpp:505–518, Rust engine.rs:1398/:1479, Zig retireRio distinct Send/Receive cases. Existing completedSendAndReceiveOrder and substituted-Transport ordered snapshots cover the contract. |
| Partial Send | sendTail uses the original Attempt window offset/remaining extent; retireRio adds successful prefix bytes, retires current Send then reposts tail; it emits one whole-attempt Send completion only at final tail. Core beginAttempt is the only claim site, so tails cannot re-claim /n. | C++ cec_engine.cpp:301–320/:535–547; Rust engine.rs:1416–1476; Zig RioAdapter sendTail/retireRio. Existing partialSendAndUDPShort explicitly checks offset2/length2 and unchanged business sendDone. |
| Receive error/mismatch | Status failure reaches one business fail/close after native retirement; short TCP fails without received_bytes credit, short UDP/mismatch settles corrupted after both directions complete. Closing cancels the other direction but does not retire it; its completion drains native ownership without another network error. | C++ cec_engine.cpp:523–555; Rust internal.rs receive settlement and engine.rs:1479–1525; Zig pure received/retireRio. Existing TCPShortAndCloseOnlyDrain, controlledCancellationIsNotLoss, failureAfterReceive and corrupted ledger fixtures retained. |
| Close/Stop/Reconnect | engine.swift:267 closes socket without changing any count; drained:261 publishes once only when all three Slot flags are zero. First close samples QPC and returns postedAt; Core anchorClose:251 anchors five seconds; repeated stopSession:398 preserves a closing deadline. Reconnect begins only after generationDrained. | C++ cec_engine.cpp:285–299; Rust engine.rs:1302–1348 sets first close_deadline and waits generation_drained; Zig adapter close/drainCompletion and pure Core drain transition. Synthetic and real995 positive/missing completion pairs remain. |
| Release/Destroy | joinAndCheck:646 loops Join-all then check-all. Coordinator snapshot follows; destroy:680 repeats guards before closing sockets/CQ, deregistering buffers, arena/contexts/notification and handles. Collection deinit repeats collective barrier. Never-started and idempotent destroy remain guarded. | C++ cec_engine.cpp:1143–1160 plus destroy:928 onward; Rust engine.rs:538–568/:1755–1762; Zig engine.zig collective joins and internal.zig:909–935. Existing stack-order, Slot-only ownership, never-started, Join positive/negative controls remain. |

Result: no additional verified source deviation was found in these six boundaries after the above fixes. This is static closure, not a substitute for optimized/runtime fault evidence.

## Architecture, files and cost self-review

Read all eight production files in full, Package.swift, the current Core/Runtime/provider fixtures and FaultDriver. Sources remains exactly main/contract/types/payload/metrics/native/internal/engine with no subdirectories or extra source files. Package.swift remains unchanged: core7 and executable main1 share explicit disjoint source lists, strict-memory-safety errors and Swift6 mode.

Pure Core/Session/Timer has no socket, RQ, OVERLAPPED, RIO API or provider counter dependency. Runtime remains generic/static; native flags/ownership do not decide business quota. New diagnostics are cold coordinator/native I/O, with POD counters and optional Native file ownership. New final accounting operates only on the joined aggregate. Three existing reviewed @safe owners remain the entire @safe list; the diagnostic type is @unsafe and adds no blanket safety claim.

Current README and behavior-differences.md now describe independent TX/RX, Session-local quota, fixed storage and runtime identity accurately. Historical remediation/optimization/runtime evidence and WIP reports are untouched and explicitly identified as historical. No script or build/test expectation was edited by this owner.

## Source-phase readiness and required next evidence

Source self-review is complete. git diff --check reported no whitespace errors; only Git CRLF conversion notices. File count/layout is unchanged. Root-owned script changes can appear in status concurrently and are not Client source-owner changes.

Before any validation, root must complete the Server source phase and an independent final static review of both Swift source stages. Then run format → Release → Debug with real CTest/reset-storm/fault/interop/ownership/safety and Client Release IR evidence. Required additions to root's existing fault-process table are send_offset_underflow (exit4/range13) and send_extent_positive (exit0/operation ledger positive).

Preserved e2e evidence requirements:

- Negative stderr must contain e2e observed_cancelled_completion=995 withheld=1, then client generation drain failed: native_error=1460, exit4.
- Positive stdout must contain e2e cancelled_completions=N withheld=0 with N>0 and exit0.
- Join failure must show both real join markers before the named release ownership failure; legal Join/order/release controls must pass.
- Every child wait stays bounded; root owns Peer startup/cleanup.

Do not claim final completion, IR zero-ARC, formal E0, performance parity or push before those gates succeed. Any actual compiler failure should be fixed in source before necessary gate reruns, with original failed logs retained.
