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

## Gaps

- Valgrind memcheck on the emitted object code of this binary: it reports a branch or an address that depends on a
  secret value on the paths the cases run. It does not see a timing difference of a variable-latency instruction
  (`div`, some `mul`), and it proves nothing about other inputs or other compilers or CPUs.
- Linux x86-64 only. Valgrind does not run on macOS arm64; ARM evidence needs another method.
- The `pilot` branch is checked only for import, link and ABI with a throwaway copy-the-point stub (known-answer
  status 10); the real kernel is not here yet.
- Differential comparison with other libraries, dudect timing and cryptofuzz are not part of this component.
