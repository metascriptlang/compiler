# X25519 assurance tooling: native export and final-binary taint

Test-only. Nothing here ships and no production file imports it.

## What it checks

A C host (`src/test/crypto/harness/x25519TaintHost.c`) links a MetaScript staticlib whose entry
(`x25519HostEntry.ms`) exports `void x25519ScalarMult(uint8_t *output, const uint8_t *scalar, const uint8_t *point)`
with `@exportName`. The host runs RFC 7748 §5.2/§6.1 known answers plus the low-order point `u = 0`
(raw output all zero) first, then repeats each case under Valgrind memcheck with exactly the 32 scalar bytes
marked undefined. The point stays defined. The output is declassified only after the call returned, and only after
the host checked that taint reached it and that the tainted call returned the untainted call's bytes.

`-d:x25519Impl=<impl>` picks the kernel: `monocypher` (the vendored C, baseline), `pilot`
(`std/crypto/x25519/pilot.cms`, after integration), and three controls that must fail:

| control | expected |
|---|---|
| `leakyBranch` (loop count from a scalar byte) | valgrind status 99, "Conditional jump or move depends on uninitialised value", first frame in `x25519ScalarMult`, host reached `STAGE taint ok` |
| `leakyIndex` (read at a scalar-derived index) | status 99, "Use of uninitialised value of size", first frame in `x25519ScalarMult`, host reached `STAGE taint ok` |
| `noop` (kernel never writes) | native host status 10 (known answer), and under valgrind status 14 (taint never reached the output) |

## Run

From the repo root, off the Mac (one `run-remote.sh` call, 2 cores; warm 20–40 s, cold about 3 min with the 22 MB download):

```
~/metascript/.gate-host/run-remote.sh --cores 2 --job "<session>: x25519 taint" -- tools/crypto/x25519Taint.sh out/crypto [monocypher|pilot]
```

It copies the `msc` on `PATH` to `x25519TaintBuilder` at the tree root, so `std/` and `runtime/` come from the tree
(the installed support tree would not see `std/crypto/x25519/pilot.cms`), builds each kernel for
`--release` (-O2) and `--danger` (-O3) with `--cc=clang --lto=off`, and exits non-zero unless every row says `ok`.
`x25519Build.sh` builds one host; `provisionValgrind.sh` fetches the tool.
`x25519Abi.sh <outDir> [pilot|monocypher]` checks the generated entry header through both C and C++ consumers.
Run it through `run-remote.sh` as above. Its old-builder control must fail with `FAIL missing entry header`;
its passing summary is `ALL ABI CHECKS PASSED`.

## Init recipe

The staticlib has no `main`. The host calls the entry module's own `__DatInit000()` then `__Init000()` and nothing
else (no `MsMain()`), as `docs/BARE.md` prescribes. The mangled name depends on the module root
(`x25519U48ostU45ntryOms__Init000` with the installed `msc`, `SsrcZtestZcryptoZharnessZx25519U48ostU45ntryOms__Init000`
with a builder at the tree root), so `x25519Build.sh` finds the one defined `T` symbol that ends with the entry's
mangled name and fails on zero or several. The `.a` still carries the prelude's other modules, whose init the host
does not call; the exported kernel reads none of their globals.

## Valgrind provisioning

`pins.tsv` pins two Ubuntu noble packages by SHA-512 (taken from `apt-get download --print-uris`, whose index apt
authenticates): `valgrind 1:3.22.0-0ubuntu3` (GPL-2.0-or-later; `memcheck.h` is BSD-style) and
`libc6-dbg 2.39-0ubuntu8.9` (LGPL-2.1-or-later), the version of the oci-u libc. Each `.deb` is extracted with
`dpkg-deb -x` into its own directory under `<out>/testDeps`; nothing outside that directory is written, no
`sudo`, no `apt install`. `VALGRIND_LIB` points at the extracted `usr/libexec/valgrind`.

Valgrind refuses a dynamic host unless it finds the symbols of `ld.so`, which on Ubuntu live only in libc6-dbg and
are searched under the fixed `/usr/lib/debug/.build-id`. Valgrind 3.22 also tries
`<--extra-debuginfo-path><real dir of the loader>/<build id without its first two hex digits>.debug`, so the script
links the pinned debug file there (`testDeps/debugroot/usr/lib/x86_64-linux-gnu/`). Linking the host `-static`
instead starts without that file but gives about 2700 errors from glibc's own start-up.
The archive keeps only the current revision of a package: when the pin 404s, take the old file from
Launchpad (same version, same hash) or move the pin.

## Environment and how to read a red

The loader and libc under test are the host's own stock ones (oci-u: Ubuntu 24.04.5, glibc 2.39-0ubuntu8.9, loader
`/lib64/ld-linux-x86-64.so.2` build id `0d77dbd4379bf0b5af3e05be7fb6af1e4cea7c96`); the run prints them with the kernel
version. The pinned `libc6-dbg` only supplies symbols for that exact build id, and `provisionValgrind.sh` fails when its
file for the host's loader is missing, so a mismatched host is a blocker, never a weaker run. No other loader or libc is
used, so a result says nothing about a different libc. No suppression file is passed and the positive row requires
`suppressed: 0 from 0`.

A red row is classified by the runner: status 99 with the kernel as first frame is a kernel finding; status 99 with a
frame elsewhere, host statuses 10 to 16, or a tool that did not reach the host's end (for example Valgrind's loader
symbol error) is an environment or harness failure and says nothing about the kernel.

## Gaps

- Valgrind memcheck on the emitted object code of this binary: it reports a branch or an address that depends on a
  secret value on the paths the cases run. It does not see a timing difference of a variable-latency instruction
  (`div`, some `mul`), and it proves nothing about other inputs or other compilers or CPUs.
- Linux x86-64 only. Valgrind does not run on macOS arm64; ARM evidence needs another method.
- Pilot source, licences and proof limits: `std/crypto/x25519/provenance.md`. The measurements below concern
  the real native pilot, not a stub; none authorize production replacement.
- Differential comparison and dudect have separate runners (`x25519Diff.sh`, `x25519Dudect.sh`); neither is
  Cryptofuzz. Cryptofuzz remains unverified and was not run for the measurements below.

## Post-wipe observations, 2026-11-01

Measured source tree `e79467f361219e9570ffcec9a35e851ab703bffd`; the later ABI runner alone was checked at
`47462f08a3f58ddafe381b9fd1bf78d47fa38755`. These are bounded observations, not a security certification.

- Linux oci-u, x86-64, clang 18.1.3, two cores, tree-root support; copied builder SHA-256
  `33d7c3dcb1594bfd92c5c87f284e69a2f29ec1a9906dcbb9e07b24d497300018`. Its containing checkout reported
  `1cc3268c91920c7fbcccb2f869036f92603e3782`; this was not an independent binary BUILD certificate.
- `builder test src/test/lang/<module>.ms --tests-in-dir --cc=clang`, separately for `cryptoX25519Assurance`,
  `cryptoX25519Pilot`, `cryptoX25519Wipe` in default/release/danger/ASan: 12 cells, 152 passed test executions. ASan flags:
  `--sanitize=address --passC=-DMS_SLAB_MAX=0 --passL=-fsanitize=address`; optimized cells used `--lto=off`.
- `MSC=$PWD/builder tools/crypto/x25519Taint.sh out/cryptoPilotTaint pilot`: 12 expected rows,
  `ALL CHECKS PASSED`, 34 s. Positive rows had zero memcheck errors and zero suppressions. An RTX attempt
  failed loader-debug pin compatibility before running a kernel; it supplies no taint verdict.
- `MSC=$PWD/builder tools/crypto/x25519Diff.sh out/cryptoFinalDiff 2000 0x25519d1ff`: pilot release/danger
  each reported `samples=6592 ran=6592 mismatches=0 unexpectedRefusals=0`; corruption/refusal/noop controls
  passed, final `ALL CHECKS PASSED`, 34 s. This is bounded seeded sampling, not Cryptofuzz.
- `x25519Abi.sh` for both pilot and monocypher: release/danger, C/C++, 48 KAT executions, paired stdout equal.
  Both printed `ALL ABI CHECKS PASSED` (5 s each); using the pre-header builder instead failed on the missing header.

Raw kernel timing uses `src/test/crypto/x25519Measure.cms`, not the async API in `std/crypto/bench.ms`.
M3 Max, Darwin 25.6.0, Apple clang 21, synced binary/support `1cc3268c919`, `--cc=clang --lto=off`:
ABBA order C/pilot/pilot/C, five rounds of 4096 calls per arm, output digests equal. A 77 s scheduling-quiet
window included timing and dudect; the machine still had load 8, and CPU affinity was not pinned.
Median microseconds/call: release pilot 68.806 versus C 58.667; danger pilot 69.566 versus C 62.875.
The pilot was slower in this workload. End-to-end API speed parity and a quiet x86 comparison remain unverified.

M3 dudect: `DUDECT_MEASUREMENTS=5000 DUDECT_BATCHES=40 DUDECT_SEED=0x1234abcd5678ef90`
with `x25519Dudect.sh out/cryptoFinalArm pilot`, release/danger. All eight rows had the expected verdict:
target/null `RESULT noEvidence`, leak controls `RESULT leakage`; final `ALL CHECKS PASSED`.
Target uncropped classes held 97400/97171 samples in each mode. The AArch64 timer counts generic timer ticks,
not CPU cycles. Neither this bounded result nor the shorter x86 smoke proves constant time.

Stripped release executable bytes (same measurement entry, empty/unused/used defines):
x86 empty=pilot-unused=C-unused 43896, pilot-used=C-used 84944;
M3 empty 71264, pilot-unused=C-unused 71272, pilot-used 105280, C-used 104792.
Unused stdout matched the empty control; used smoke digests matched. This shows no measured DCE advantage.
Do not pass `-d:cryptoEmpty=false` or similar: `when(flag)` tests presence, so omit false flags.

Read-only M3 follow-up (2026-11-02, same existing artifacts): `nm -n`, `size -m`, `otool -tvV` and parsing
Mach-O section/signature load commands confirmed that empty and both unused binaries have identical complete
`__TEXT` section bytes. Their `__text` is 22320 bytes, SHA-256
`767b05958a751a77560b0b691f678dcbf1cb7ed865686f84a96192719f888dca`.
The entire 8-byte unused-file delta is `LC_CODE_SIGNATURE` length (760 versus 768 unstripped), not retained code.
Used pilot/C `__text` is 36684/39516 bytes; bounded crypto symbol intervals are 7096/9948 bytes including alignment.
The expected field/inversion/wipe closure is reachable, with no unrelated named crypto API retained. Total file
size is therefore not a kernel-size ranking. This supports DCE for these old-compiler M3 samples, not new-compiler,
x86, production-API or formal exhaustive-reachability certification.

A source-review aid compared all 13 ported field functions with the pinned fiat-crypto file in
`std/crypto/x25519/provenance.md`: local variable types matched; 657 statements were compared after cast/address
normalization, with differences only in the two `fiat_25519_cmovznz_u32` mask-setup statements. Those differ within the stated
0/1 selector contract only in spelling (boolean normalization and the uint32 all-ones mask). This comparison
omits cast semantics and is not a proof of field bounds, translation correctness or optimized code behaviour.

## Native thin-LTO investigation, 2026-11-02

No kernel change. Source tree `9fa1cf6cd25ac510d253fe50d9d068fbb852d904`, M3/Apple clang 21, installed
binary/support `2a52560f0bc`; copied tree-root compiler SHA-256
`948d6ef05cf843c3c26ec74528e6bd3387218c954ab7307de1808568f750751d`.
`msc build src/test/crypto/x25519Measure.cms --release --cc=clang --lto=<off|thin>` was run separately
for pilot (`-d:cryptoPilot`) and C (omit that flag), both with and without `-d:cryptoSmoke`.
All four 8-call smoke outputs had equal digests; the driver printed `LTO_BUILD_SMOKE_PASS`.
These short, non-quiet timings are not speed-parity evidence; no LTO taint/security verdict was established.

`nm -n` and `otool -tvV` on the resulting pilot used executables show eight whole-field symbols with LTO off,
five with thin LTO. The separate inversion symbol disappears under thin LTO, but field calls remain.
The scalar-multiply body's disassembly expands from 512 to 1633 instructions; its `sub sp` reservation changes
from `0x2c0` to `0x590` (not a complete call-chain stack bound). Inlining is therefore not itself proof of a win.
Pilot used-executable SHA-256: off `2f80c0994754f553ad50a0e87e62334f235c9ea564b86b5eccb718319be9c1e9`;
thin `d00d1293c4be7e7aeb5c539d2c0e41353a736a9d5718bf94fc5b72db040f0fc4`.
A quiet, matched workload and unchanged security checks are still required before choosing flags or code changes.

## m1m follow-up, 2026-11-02

The person selected m1m for ARM runs. Destination guards verified `Metacrafts-MacBook-Pro`, Apple M1 Pro,
8 cores, Darwin 25.5.0, Apple clang 21; the `run-remote.sh --mac` local-M3 fallback was forbidden.
Source tree `1c62cb278ef873f48cb7b507cd024b63a6a0cc12`; compiler/support `2a52560f0bc` and compiler hash
match the thin-LTO investigation above. Kernel, field, wipe and Monocypher source hashes were checked unchanged.

Through `run-remote.sh --mac --cores 8`, each of `cryptoX25519Assurance`, `cryptoX25519Pilot`,
`cryptoX25519Wipe` ran with `--tests-in-dir --release --cc=clang --lto=thin`: 24/11/3 passed (38 total),
16.94/12.06/11.32 s. This was release only, not a repeat of the old compiler's four-mode/ASan matrix.
Raw pilot/C 8-call smoke digests matched. Fresh empty/unused/used builds used the same release/thin flags:
empty and both unused executables had identical complete `__TEXT` section bytes (`__text` 24848 bytes).
Their file lengths were 75608/75616/75616 bytes; the 8-byte delta is signature length (728 versus 736).
Used pilot/C `__text` was 40952/41376 bytes, with no unrelated named crypto API symbols observed.
This is bounded section/symbol evidence for the measurement fixture, not a production-API reachability proof.

A separate, hash-guarded raw ABBA run rebuilt both used executables in one remote call with the same flags:
C/pilot/pilot/C, five 4096-call rounds per arm, ten samples per implementation. All output digests matched.
Median microseconds/call: pilot 86.201, C 69.706 (pilot/C 1.2366); ranges 85.724–90.239 and 69.250–74.540.
The m1m scheduling-quiet ledger window was 06:10:43–06:10:59Z, with all 8 cores reserved and no CPU affinity pin.
Load averages were still about 21: this is not an idle-machine absolute budget or public async-API benchmark.
The driver printed `M1M_RAW_ABBA_PASS`, coordinator passed and recorded QUIET END/rc0. Speed readiness was not met.

## Loose-carry candidate, 2026-11-02

Measured source tree `d998aeb905450ceeb2fcc2f9d69a8e20f7c1a508` is base tree
`0613127bbba4077a6f1eeb0b6f6427922c2b73c5` with only `pilot.cms` changed
(SHA-256 `0d390d3bf4816de174a9e76363729f64ad2b409c0dfa166e0463d88448598257`). Field/wipe/vendor bytes
remain those pinned above. The pinned generated add/sub take tight inputs and produce loose outputs;
`carry_mul`, `carry_square` and `carry_scmul_121666` accept loose inputs. Source review traced every ladder
consumer and found tight loop-carried coordinates. This permits deferring eight carries per step (2040 per
scalar multiply); it is not an inherited proof for the translation.

The three inline representation pins in `pilot.cms` failed their limb assertions on the old helpers:
`Tests  0 passed | 3 failed (3)`. The old-red verifier's summary-format assertion failed afterward; the
saved actual test failures, not that verifier status, are the red evidence. Candidate m1m commands were
`./.matrix-builder-8726a6fc test <module> --tests-in-dir <flags>`, with a guarded root-adjacent builder. Modules/counts were
`pilot.cms`/3, `cryptoX25519Assurance.ms`/24, `cryptoX25519Pilot.ms`/11 and `cryptoX25519Wipe.ms`/3:
- default: `--cc=clang --lto=off`;
- release/danger: `--cc=clang --lto=thin` with `--release` or `--danger`;
- ASan: `--cc=clang --lto=off --sanitize=address --passC=-DMS_SLAB_MAX=0 --passL=-fsanitize=address`.

Output: `MATRIX_PASS cells=16 executions=164`; each whole cell took 4.828–14.828 s, with no failed summaries
or sanitizer errors. Compiler SHA-256 was `948d6ef05cf843c3c26ec74528e6bd3387218c954ab7307de1808568f750751d`,
the same executable as assertion-red. An earlier zero-cell guard stop compared a full `.local` hostname with
a short name; changing only the producer to `hostname -s` preserved the exact host/CPU/hash guards.

On Linux x86, `tools/crypto/x25519Taint.sh out/cryptoPilotTaint pilot` passed 12/12 rows in 34 s, positive taint rows having
zero errors/suppressions. `tools/crypto/x25519Diff.sh out/cryptoLooseDiff 2000 0x25519d1ff` passed 14/14 rows in 45 s:
release/danger each sampled 6592 cases with zero mismatches or unexpected refusals; negative controls passed.
Both printed `ALL CHECKS PASSED`. These runners use LTO off, not ARM thin LTO, and are not Cryptofuzz.
Actual Linux compiler SHA-256: `0849f8edfa8ea2683c81aea454ca587d812ccee2af28cdecc2872861bb6589a3`.
Its `msc-builds/2a52560f0bc` path and installed BUILD (`fa6dca871`) disagree; that metadata is not a certificate
of the executable's source revision. Source/compiler hashes were unchanged before/after both lanes.

A single strict `run-remote.sh --host m1m --cores 8` call rebuilt old-with-identical-pins, candidate and C,
plus empty/unusedC/unusedPilot, from `src/test/crypto/x25519Measure.cms`. All six used
`--release --cc=clang --lto=thin`, isolated caches and the same guarded compiler/Apple clang 21. Preflights
preceded the quiet window. Order C/old/new/new/old/C produced ten 4096-call samples per implementation;
all 30 timed digests matched `a7407818217014dd368e5222c943950647ec70516e2cda15e191761d98c42061`.

| Raw kernel | Median µs/call | Range |
|---|---:|---:|
| Old + identical pins | 86.930 | 86.204–100.656 |
| Candidate | 77.269 | 77.191–78.159 |
| C | 69.585 | 69.328–84.481 |

Candidate/old time = 0.88886 (11.11% lower); candidate/C time = 1.11041 (11.04% higher). The scheduling-quiet ledger
window was 08:41:36–08:41:46Z under the documented Mac/no-gate exception, not an idle-machine guarantee.
Load averages rose from 13.02/8.66/11.24 to 14.68/9.16/11.39; execution was unpinned.

Empty/unusedC/unusedPilot stdout and every `__TEXT` section payload were identical: `__text` 24848,
`__const` 24, `__cstring` 676, `__stubs` 552, `__unwind_info` 264 bytes; each file was 75608 bytes with a
728-byte signature. Used old/candidate/C `__text` was 40952/39760/41376 bytes. Relevant used kernels were
present; no unrelated named crypto API symbols were observed. Output: `M1M_MATCHED_PASS`.
Raw command/stdout and extracted measurements are at `/tmp/crypto-m1m-matched-edf71ed01b/`; the matching
remote evidence is `m1m:~/work/rr-recompiler-182168b2/out/crypto-m1m-matched-edf71ed01b/`.

This is bounded raw-fixture DCE and performance evidence, not public-API reachability or a new constant-time
certificate. Speed readiness still fails; x86 and real `std/crypto/bench.ms` pilot performance remain unmeasured.
Production/API selection remains unchanged and the provider-refused Cryptofuzz task remains blocked.
