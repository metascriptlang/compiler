# Native toolchain handoff to the Mac

Checkpoint: 2026-11-01. The checked code baseline is
`3ae83003c1e96eb7c7f2864887b79cbdbcdb8699`, tree
`43a6a60cee4bc0367bc5c12f42b6188b96132ebd`.

The Mac takes source-writer ownership of functional native runtime and bundle
continuation. The Windows writer has stopped that implementation and parked its
unfinished draft. A separately requested Windows authoring-standard refactor of
already committed tooling must coordinate path ownership, preserve public APIs
and results, and stay out of this handoff push. Do not restore the parked draft
on two machines or implement the same runtime step twice.

## Product checkpoint

`prepareWindowsEngine.ms` was built as a reusable native Windows executable and
used on real installed LLVM 23.1.0. Prepare and a separate `--verify` both exited
0, with no stderr: 20.102 s and 5.379 s respectively, under inherited two-core
affinity. These shared-load durations are not performance measurements.

The resulting engine has HOST `x86_64-windows`, VERSION `23.1.0`, and IDENTITY:

```text
12aa46512882b6684956729d72ba3ca0269130bd187ee051c0cbcd16e18cc3ca
```

The manifest covers 382 files, 16 PE files and 790643796 bytes, including HOST
and VERSION. The complete directory has 384 files and 790684917 bytes; the two
additional files are FILES.sha256 (41056 bytes) and IDENTITY (65 bytes).
The operator-license receipt explicitly does not certify redistribution.

The CLI binary SHA256 is
`26d89af3a639c1e5e313d015e8bc241b88a72e7d94e4cc2b53243790528dc8d2`.
Its controlled checks passed 98 library contracts and 72 producer checks, with
zero skips; help exited 0 and missing arguments exited 2. These are native
Windows proofs, not migrated Raiser test drivers or other-host certification.

Windows-host-only artifact: `C:/Users/metacraft/msprobe/tc/engine-native`.
It is not a portable input path for the Mac and the binary/artifact is not in
Git. Raw Windows evidence remains in ignored `out/native-verify/`, notably
`windows-real-engine2-results.md` and the corresponding stage captures.

**The full SDK is unfinished.** The requested Windows-host destination
`C:/Users/metacraft/msprobe/tc/bundle-native/msc-toolchain` was absent at this
checkpoint. Engine-only output is not that bundle. Runtime, application,
platform, sanitizer, redistribution and performance acceptance remain open.
All 33 Python programs remain; no whole-program/caller cutover or deletion has
been completed. Do not invoke a Python fallback or silently narrow targets.

## Support dependencies are not carried by this branch

The successful native build used private compiler/support from
`wt/raiser-tooling-fixes` at `fc824283b`, tree
`e9057c2498a360344d9389d646970eed8d9f6829`.
That stack includes `f154e6d19` (fallible complete directory enumeration),
`94cb94a5a` (native link-like metadata), environment/raw-child support and the
exact landed Windows CSPRNG dependency consumed by `fc824283b`.

Those support commits are not ancestors of this toolchain branch. Obtain and
inspect the separate support branch, or establish equivalent landed APIs,
before building the new tools. Do not assume this handoff pushes that branch,
settles its DRC ancestry, passes its ready/land gate, or deploys its support.
Support publication has separate approval and ownership through Nim Audit.

The consumer worktree's exact `./msc check src/index.ms` at the checked baseline
exited 0 in 14.293 s: `OK no type errors in 450 module(s)`. It emitted 407
warnings, 572659 bytes of stderr; it was not warning-free. The local compiler
SHA256 was `411b8ab66ac2f6299e2ed87975781de93a585eaf982e36f7805909e013edf70b`.
The root index does not import this tooling, so that check does not prove the
new tool imports against another machine's compiler/support. It is also not the
private support compiler's different 488-module/439-warning check cohort.

## Parked runtime-input RED: text needed because the draft is not pushed

The Windows-only local drafts are preserved byte-exact in ignored
`out/next-native-runtime/runtimeInputs.ms` and
`out/next-native-runtime/archiveBatchContractTest.ms`. The latter added 19 lines
to the tracked test; only those lines were reversed to restore its HEAD version.
No stash/reset, foreign cleanup or discarded source was used. Neither draft is
in this push; do not import a nonexistent `runtimeInputs` module from this tip.

The draft followed the input-normalization and copying contracts of
`prepareRuntime.py`, reusing `archive.ms`, `argumentBatches.ms`, native filesystem
APIs and `processCapture.ms`. The expanded archive pin called the production
normalizer on an argv-budget-exceeding archive and an empty archive.

Observed evidence:

- Missing-module source RED: 193 ms. Three subsequent own call-contract errors
  were corrected; final source check exited 0 in 871 ms with no stderr.
- The native app built 46 modules, exit 0 in 28.505 s, size 1713152 bytes;
  SHA256 `a45b4fb748c56ee27ad248295b90df7f65c1c7598b6a70555356eeb20a84278f`.
- Its first run stage was refused before child launch because the load snapshot
  showed 34 build processes. The explicitly authorized finish reused that EXE.
- The actual run exited 1 in 2.684 s, with stdout empty. No final 15-case GREEN
  summary exists. The failed fixture, binary, logs and manifests were retained.
- The failure is a consumer bug, not RNG failure or a compiler bug:
  `randomUUID()` returns `Result<string, CryptoError>`, but the draft concatenated
  the whole successful Result into a scratch path. Literal JSON
  `{"ok":true,"value":"UUID"}` in that path caused Windows errno 22.

Follow the existing `windowsEngine.ms` function `claimPartial`: inspect `.ok`,
map `.error.message`, then concatenate `.value`. A Result-returning normalizer
can use this shape:

```ms
const token = randomUUID();
if (!token.ok) { return Result.err(token.error.message); }
const scratch = join(dirname(path), "normalizeInput-" + token.value);
```

The corrected draft has not been built or run. A changed-source check requires
a fresh small-app build and new output names, not reuse of the old EXE. Do not
retry an executed child without the required new resource authorization.

## Remaining integration and preserved foreign work

`prepareRuntime.py` was read completely through its CLI: default WASI/two glibc
profiles, explicit musl/FreeBSD profiles, shared overlays, archive normalization,
aliases, headers, notices, compile/link/macro checks and relocation proof. Reuse
the committed compiler/link/config/binary-format/process/publication seams.
The whole native runtime, Windows, Darwin and C++ producers plus Raiser proof
and test drivers remain unfinished. Preserve cfg order, relative `<CFGDIR>`,
no-default-config policy, deterministic unique archive member names, bounded
Windows argv, provenance and no-replace publication. Helpers are not program
cutovers. Full bundle assembly must not be replaced by an engine-only label.

The Windows worktree retains 16 inherited tracked WIP files: `docs/TESTING.md`;
`prepareBundle`, `prepareCppRuntime`, `prepareDarwinRuntime`, `prepareEngine`,
`prepareLinuxEngine`, `prepareRuntime` and `prepareWindowsEngine`, each `.py` and
`Test.py`; plus `prepareWindowsRuntime.py`. Tool paths are relative to this
directory. These are earlier coordinator integration from the C++, platforms,
sanitizers and Windows-source lanes; no individual historical session owner
was verified for every hunk. They remain binary-diff identical to the snapshot
before the native producer work. Inherited untracked Python references and
C/C++ fixtures were likewise preserved and are not included in this push.

The checked root/native-engine consumers do not import those docs/Python files,
but the full SDK is unfinished with or without that WIP. Do not stage or delete
it as part of the authoring refactor. Mac continuation owns the functional work;
coordinate any shared contracts before another writer changes these paths.
