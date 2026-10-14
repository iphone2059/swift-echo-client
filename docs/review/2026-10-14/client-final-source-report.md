# Swift Client final source closure — 2026-10-14

Owner: /root/client_final_source, continuing /root/resume_client. Evidence is **S0/S1 static source and fixture review only**. No formatter, compiler, build, Swift probe, executable, unit test, gate, commit or push was run. Historical client-report.md, resume-client-report.md and REVIEW_CHECKPOINT_2026-10-14.md remain unchanged.

The parent verified clean main/origin before the resumed source work; this owner observed main...origin/main = 0 0 and main on entry and again at handoff. Work remains in the existing repository with one main and no new branch/worktree. Concurrent parent-owned PS1/verification changes are outside this owner's source edits. The latest user-authorized **SwiftPM-only** build/test workflow supersedes historical CMake/CTest wording; all existing PowerShell gates must remain.

## Closure of resume-client-review.md findings

1. **Per-packet native arbitration and startup.** Sources/engine.swift consumePacket always services a delivered notification through the ordinary bounded drain before acquiring the next packet. An acquired STOP calls beginStop immediately. arbitrateTimers retains the sessionCount+2 packet limit, direct 2*sessionCount CQ-record budget and timestamp sampled before that direct pass. cecRunWorker starts the normal Core/Transport actions before observing preexisting Stop. No service:false alternate policy remains.
2. **Pinned notification lifetime.** cecDestroyWorker closes CQ, deregisters buffers and releases the arena/Slot storage, then closes IOCP, and only afterward releases the same pinned notification OVERLAPPED allocation/address. The Resources implicit release guard additionally requires port/CQ/thread handles and registrations retired before its members deinitialize. This is source-order evidence; no runtime port/notification instrumentation is claimed.
3. **Every aggregate destruction route guarded.** CECEngineWorker.deinit checks native ownership and started-worker Join/stopped/Core predicates. CECRioTransport.deinit checks Slot/aggregate/notification ownership and storage retirement. CECEngineWorkerResources.deinit checks Slot ownership then raw dependency retirement before any member deinitialization. Explicit destroy repeats the same shared guard. Unsubmitted standalone raw owners remain usable.
4. **Cold zero-counter helper.** cecBuildPattern returns an empty UniqueArray only for the binary/printable counter fixture with size0. Existing CECPatternTests initializationBoundaries assertions stay intact. Production/CLI cecPatternByteCount and /z validation remain strict.
5. **Pacing timer resolution.** Native CECTimerResolutionOwner is noncopyable and statically generic over a preparation-only API. It requests period1 iff /i != 0 and calls timeEndPeriod only for an accepted request. runStarted retains it across all later return paths. Request failure reports the native status at timeBeginPeriod(client pacing) and returns exit4. Package.swift links Winmm alongside Ws2_32. No dynamic dispatch, request-path switch or scheduling substitute was added.

The preceding implementation owner wrote the production repairs for findings1/3/5 and the direct-deinit/timer fixtures. The parent repaired findings2/4. This continuation inspected those current repairs, added only the missing native arbitration fixture, and updated current documentation.

## Focused native arbitration fixture

Tests/swift_echo_clientTests/CECDrainTests.swift adds queuedControlKeepsPacketOrderDuringTimerArbitration with stopFirst=false/true inside the existing serialized suite. It uses a real IOCP and PostQueuedCompletionStatus for STOP and the pinned notification, with shared Stop/Fatal flags clear. A deterministic substituted CQ provides already queued successful RX/TX pairs. A due timer at deadline0 exercises the production arbitrateTimers packet path through the existing package helper cecArbitrateQueuedTimers.

Expected source-derived outcomes:

| Packet order | Native CQ closing trace | CQ calls | New RX/TX posts | echoed / claimed / cancelled | bytes / sentBytes / receivedBytes |
| --- | --- | --- | --- | --- | --- |
| STOP → NOTIFY | [true] | 3: one pair, ordinary empty, direct empty | 0 / 0 | 0 / 1 / 1 | 0 / 0 / 0 |
| NOTIFY → STOP | 64 false entries, then true | 65: ordinary64 pairs, direct closing pair | 64 / 64 | 64 / 65 / 1 | 64 / 64 / 64 |

Both require lost/networkErrors0; attempted==terminalCount; pending/active/liveSessions/timers/Slot and aggregate outstanding0; done state and once-only drainReported; exactly one acquired notification and the corresponding legal arms1/2. The CQ fixture stops returning data beyond65 calls to bound a broken implementation. The existing continuouslyNonemptyQueueServicesControl assertions remain unchanged, including first drain64 calls and second cumulative66 calls. No additional FaultDriver mode or redundant test matrix was introduced by this continuation; SwiftPM's existing test target discovers the new fixture.

Independent reviewer /root/client_closure_review read the new fixture and confirmed both paths and assertions statically, with compiler/runtime evidence still pending.

## Current new FaultDriver contracts from the prior implementation

The parent owns process-table wiring. These names are supported by the actual current driver; they are not hypothetical aliases.

| Mode | Exit | Required stdout | Required stderr |
| --- | --- | --- | --- |
| aggregate_deinit_positive | 0 | aggregate deinit positive owners=3 | empty |
| worker_deinit | 4 | none | client worker release native ownership failed: native_error=996 |
| transport_deinit | 4 | none | client worker release native ownership failed: native_error=996 |
| resources_deinit | 4 | none | client worker release native ownership failed: native_error=996 |
| worker_deinit_unjoined | 4 | none | client worker release precondition failed: native_error=5023 |
| timer_resolution_positive | 0 | timer resolution positive begin=1 end=1 disabled=0 | empty |
| timer_resolution_failure | 4 | none | timeBeginPeriod(client pacing) failed: native_error=97 |
| send_offset_underflow | 4 | none | client completion exceeds posted range failed: native_error=13 |
| send_extent_positive | 0 | operation ledger positive | empty |

Each negative direct-deinit fixture installs a non-heap stack arena before consuming the aggregate. Premature arena release would reach the different client arena release diagnostic, so the required named ownership/precondition diagnostic proves the guard precedes member freeing. aggregate_deinit_positive consumes all three legal owner types and uses VirtualQuery to require actual MEM_FREE after each arena release. Timer positive proves both the disabled zero-call and enabled begin1/end1 lifetimes; failure proves begin1/end0 and the unchanged exit4 classification. Existing operation, real995, Join-all and explicit-release controls remain.

## Overlay integration and unchanged architecture

The user's explicitly supplied source overlay was audited read-only; see client-overlay-source-audit.md for pinned input hashes and each disposition. Its sole Swift patch is already covered more completely by current retireRio. No old Apply/ZIP script was executed, no entire checkout was replaced, and no new applicable Swift fixture was found.

Production Sources remains exactly eight flat files: main, contract, types, payload, metrics, native, internal, engine. Core/Session/Timer remains independent of socket/RQ/OVERLAPPED/provider counters. Runtime remains statically generic, ActionBatch/Completion batch uses InlineArray, Core/Timer retains bounded startup allocation, and new timer setup/deinit/diagnostics remain cold. Three reviewed @safe owner declarations remain; no blanket @safe exemption was added. Existing joined finite terminal accounting and CEC_DIAG_FILE snapshot ordering remain unchanged.

README and behavior-differences now describe implicit guards, actual packet order, timer resolution and IOCP-before-notification lifetime, while preserving historical WIP and verification records. git diff --check completed with exit0 and only Git CRLF conversion notices. This is whitespace/static evidence, not build validation.

## Handoff

The Client planned source/fixture work and overlay comparison are complete for the parent's unified source-phase decision. Independent full-source closure review and the Server's corresponding closure remain parent responsibilities. Only after both source stages close may the parent run format → Release → Debug through SwiftPM and retained PowerShell gates, including ownership/safety, native positive/negative process boundaries, real995/Join/order, reset storm, interop and Client Release IR evidence. Preserve original failures and repair source before necessary reruns. Final acceptance, optimized ARC/config-copy behavior, formal E0, binary/performance parity and commit/push remain unproved until their actual gates and evidence succeed.
