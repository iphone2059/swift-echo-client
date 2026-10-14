# Swift Client carried overlay source audit — 2026-10-14

Owner: /root/client_final_source. User explicitly authorized including the carried overlay in the ongoing alignment. Input directory: C:\Users\Administrator\echo-project\cpp-echo-client\swift-echo-client-alignment-overlay\swift-echo-client-alignment.

Read-only inspection covered README.md, docs/CHANGELOG.md, BASELINE.json, patches/Apply-Alignment.ps1, patches/cec_fault_process_tests.ps1 and Build-CompleteSourceZip.ps1. There is no docs/BASELINE.md; the actual baseline is BASELINE.json. **No Apply/ZIP/build/test script was executed.** No source was imported wholesale, no clone/branch/worktree was created, and no carried input file was changed.

## Provenance

The overlay pins iphone2059/swift-echo-client at d8a847ab5e7dc55fbea636a030e71f4b16eda25a, the same historical Client source baseline as the current alignment review. BASELINE lists the exact eight production source filenames and labels this as a source overlay/Windows ZIP builder rather than a full source checkout. Its recorded Windows build status is unexecuted; the carried artifact cannot supply current T1/T2/P1 evidence.

| Input relative path | SHA-256 |
| --- | --- |
| README.md | 030e96897f58218fc072d892bc0f4e68871edb440158d7286036bc45006d6145 |
| docs/CHANGELOG.md | b9f28c2f0ed7ead9f92ad623ca9d83ab40fa5e35c647b41af3619189c9adf410 |
| BASELINE.json | 92315c098bb1b89c46668fea1d237db74994f7008e9370b7128543f4efcc2ea6 |
| patches/Apply-Alignment.ps1 | 6d6d9291e4a3f21608d2f16d37dc265afb532f09c1517f2171bb143fc18be0c6 |
| patches/cec_fault_process_tests.ps1 | eeebc6620b0b6d791a0eeb75d60c5abb8c6db911e6cafdd9e907f0629758eb66 |
| Build-CompleteSourceZip.ps1 | 788030091639c7c163b7cd91362fa793a18d34392be0f92265e303be347adf32 |

## Item-by-item source disposition

| Carried item | Current-source comparison | Disposition |
| --- | --- | --- |
| Validate sendOutstanding before sendPostedBytes-sendOffset | Current retireRio checks the matching Send/Receive operation ownership before any posted extent arithmetic or count retirement. duplicate_operation preserves a corrupt unused sendOffset=Int.min to establish ownership-first ordering. | Already covered; no duplicate mutation. |
| Validate sendOffset<sendPostedBytes before subtraction | Current Send validates posted length>0, length<=maximumAttemptBytes, offset>=0 and offset<original length, then subtracts. send_offset_underflow supplies Int.min; send_extent_positive proves a legitimate remaining tail. | Already covered more completely; retain current source. |
| Overlay comment calls offsets unsigned | Current fields are signed Int. The overlay's upper-bound-only guard does not reject a negative Int.min, which can still overflow subtraction. | Do not import the inaccurate comment or weaker guard. |
| Rename bad-send extent stage to client send completion accounting | Current shared malformed-extent stage is client completion exceeds posted range / native_error13; unowned operations retain client duplicate RIO completion /13. Existing focused modes and reference review establish those specific boundaries. | Do not rename current shared diagnostics based on an older unexecuted overlay. |
| Replace Tests/cec_fault_process_tests.ps1 | Overlay lists supported provider/drain/Join/release modes plus the real995 negative/positive peer wrapper. The parent owns current PS1 and the authorized SwiftPM-only migration. The carried wrapper has weaker/absent exact checks for several cases and defers async stdout/stderr reading in the peer case. | Handed to parent for logical comparison; no wholesale overwrite. |
| Swift fixture changes | Apply-Alignment edits only engine.swift and copies one PS1. No Swift unit or FaultDriver source patch is carried. | Nothing missing to import. |
| Pinned ZIP/build workflow and historical CMake/CTest requirements | Builder creates a detached checkout and can execute an old CMake/CTest-era flow. Current user requires main-only and SwiftPM-only while retaining all PowerShell gates. | Preserve as carried historical provenance; do not execute or adopt its workflow. |
| README/CHANGELOG warnings about uncompiled code and no parity claim | The statements correctly bound the overlay's evidence, rather than proving current code. | Preserve input unchanged; current reports independently retain S0/S1 limits. |

Source integration result: **all applicable Swift source logic is already present**, with stricter signed-range validation. No additional production source edit was justified by the overlay. The native IOCP arbitration fixture completed in the same source phase derives from the independent current-source review, not from this carried overlay. Sources remains8 flat files. Original historical reports and unexecuted-build claims were not rewritten.

This report establishes carried-input coverage only. Parent-owned fault-process glue comparison, full independent closure and unified format/Release/Debug evidence remain separate. No compiler/runtime/performance result is claimed.
