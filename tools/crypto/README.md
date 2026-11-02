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
