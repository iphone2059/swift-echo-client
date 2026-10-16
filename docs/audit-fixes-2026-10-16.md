# CQ scratch ownership (2026-10-16)

The pinned noncopyable transport now owns a fixed 256-entry RIORESULT InlineArray. It is initialized
once and reused across batches and separate drains. The mutable span ends before completion
handling mutates transport state; processing still reads only the provider's returned prefix.

The continuous-drain test verifies the provider always receives that stable storage address and
preserves an untouched tail across both ordinary and cancellation drains. Existing release gates
also inspect optimized hot paths for ARC operations and full configuration copies.

Batch v1, native completion ownership, CLI and statistics remain unchanged. This source change
makes no measured throughput or CPU improvement claim.

Validation ran in order: `format.ps1`, `build_release.ps1`, `build_debug.ps1`; all exited 0.
Release passed all 11 verification gates, including optimized-hot-path IR checks; Debug passed all 10
applicable gates. Both modes include unit, source policy, ownership, memory policy, fault boundaries,
process contracts and reset storm. Their manifests record the same `Sources/engine.swift` SHA-256:
`99c7859d2e4023c190953a56e70f2034fa3a2388a49048f090ba6099d3574839`.
Every manifest source-file hash and executable hash was checked against the final working files.

| Product | Executable SHA-256 |
| --- | --- |
| Release (`-O`) | `e32139678da5093bde5a5315ed6069844a5917750c6e05b00715cf6d91604690` |
| Debug | `309d9ad89e775dc15419c064e1e1bc26d888a1c072d0d86113ab5d87124bc88e` |

The existing optimized-IR gate requires an auditable worker-loop definition when private completion
helpers are inlined. `cecRunWorker` now has `@inline(never)`; it is entered once by each worker thread,
and completion helpers remain free to inline. This preserves the gate without adding a per-batch call.

Earlier failed attempts remain retained: two pointer-projection approaches did not satisfy Swift's
mutable-span lifetime rules, a corrected method needed an explicit `unsafe` call annotation, and a
complete functional run then failed the IR gate because the worker loop had itself been inlined.
The final transport method borrows directly from `inout self`, and the source annotation above keeps
the expected loop visible. No test expectations or verification scripts were changed to accept these
failures. The complete fresh gates above validate the final source.

Retained final coordinator logs and results:
`C:\Users\Administrator\echo-project\.superpowers\audit-fixes-20261016\swift-echo-client-20261016T152500711Z`.
Release verification directory: `.build/verification-release/run-20261016T152528770-af062a71de1245c8852d817b05ab03dc`.
Debug verification directory: `.build/verification-debug/run-20261016T152719093-d83d367b4e9a44efa29a6dbb010837db`.
