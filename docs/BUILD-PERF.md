# Build Performance — Roadmap

## Measuring by flow

A whole-compiler A/B costs 45-60 minutes and names no flow. Every instrument below writes rows
`<source>\t<flow>\t<metric>\t<value>` (source `msc` `drc` `emit` `proc`; metric `ms` `instr` `count`
`bytes`), and `src/bench/compiler/run.ms` turns the rows of a base and a candidate compiler into one table
per program, so a change shows its own delta in about a minute.

| Instrument | Measures | Switch on |
|---|---|---|
| `msc` rows | the compiler's passes, analyzer steps, phases, emit and cc | env `MSC_FLOWS=<file>` |
| `drc` rows | allocations, rc operations, cycle registrations and collections of a program | build with `--passC=-DMS_DRC_STAT`, run with env `MS_DRC_STAT=<file>`; an `msc` built that way reports its own runtime flows |
| `emit` rows | per function counts in emitted C (rc ops, pins, atomics) | `msc run src/bench/compiler/emitCostScan.ms <emit dir>`, or `--diff A B` for a ranked table |
| `proc` rows | whole process: instructions retired, wall, max rss | the runner adds them itself |

The runner's environment and program names are the header of `src/bench/compiler/run.ms`.

**A/B recipe.** Build the candidate at the worktree root (`msc build src/index.ms --danger
--lto=off --output=msc`), keep the previous build as the base, then

```sh
MSPERF_BASE=/path/to/previous/msc MSPERF_PROGRAMS=711,self nice -n 10 msc run src/bench/compiler/run.ms
```

Check `uptime` first and do not start a second compile beside it. `MSPERF_SELF=1` runs one binary as
both arms: that is the noise check, and every row of it should carry no mark.

**Reading the table.** Rows sort by the size of the instruction delta, then the count delta.

- Counts and non-process bytes are exact: they do not depend on load or host. `=` means identical in
  every run of both arms; `≠` means the change moved the number. An exact row that varies inside one
  arm is read as timed.
- Timed rows (`ms`, `instr`, process bytes) compare medians. `*` marks an `instr` or bytes delta over
  3 times the noise (the larger sample coefficient of variation of the two arms), over 1% and, for
  `instr`, over 5M instructions; `ms` rows are wall time under load and are never marked. No mark
  means the move is not shown to be real. Resolution is about 2%: on 19 runs of one binary on 711
  (2026-10-25, load 50-90) the rows of 1G and more spread 0.37% (sd, median), a 2% move on them was
  caught 81% of the time at 5 runs, and with the 5M floor no 3-vs-3 or 5-vs-5 split of those runs
  carried a false mark (32% of the 3-vs-3 tables did without it). A claimed 1% move needs a rerun of
  that program with about 15 runs per arm.
- `new` / `gone` is a flow only one arm wrote. A header line names the sources each arm produced:
  a compiler without `MSC_FLOWS` yields only `proc` rows.
- Coverage: the leaf flows of phase A (`pass.*`, `analyze.*`, `a2.mono`, `a2.macro`, `a2.lower`) over
  `phase.A`, and the `phase.*` rows over the `msc total`. A low share means the table leaves a flow
  out and its delta cannot be located in it.

**Self check on the merged instruments, 2026-10-25** (`msc-cand` of `wt/perf-flows` built
`--gc=drc --danger --lto=off`, `MSPERF_SELF=1`, `711`, 3 runs, load 63-73): no row marked; coverage
97.0% of `phase.A` in leaf flows and 100.0% of the `msc total` in `phase.*` rows. `phase.setup`
(session start, cache init, parser registration) is 4.1G of 30.5G instructions here against 1.1G in
a warm run from the worktree, so it is a flow worth its own look.

**Measured noise, 2026-10-25** (macOS arm64, installed `msc` v0.3.4 as both arms, `711` built with
`--emit=c`, 3 runs, load average 100-140 during the run): process instructions 25.49G against 25.64G,
median difference +0.6% at noise 0.3% (no mark); wall time noise 17% and max rss noise 11%, so wall
time and rss under that load show nothing. Not measured: Linux (`perf stat` and the `/usr/bin/time -f`
fallback are written, not run), and `rt:` programs.

## Measured 2026-11-13 — an engine built on a Mac assumed that Mac's Apple linker

Bundle `8d7d908f2630` (the engine built on m1m by the producer), installed on the Mac and m1m on 2026-11-12, left
every arm64 Objective-C class message undefined at link: `ld64.lld: error: undefined symbol:
objc_msgSendClass$stringWithUTF8String:$_OBJC_CLASS_$_NSString`. Haro's native release met it first, with 20 such
symbols from Ion and Void. The bundle before it, `be33328d1c99` (the stock release engine), links the same file.

clang's driver passes `-fobjc-msgsend-class-selector-stubs` to cc1 on arm64 when the linker version is 1250 or
newer, and `-fobjc-msgsend-selector-stubs` from 811.2 (`clang/lib/Driver/ToolChains/Darwin.cpp`, LLVM 23.1.4). With
no `-mlinker-version` it takes `HOST_LINK_VERSION`, which CMake reads from the build machine's `ld -v` unless the
engine is linked by lld (`clang/CMakeLists.txt`). The two engines, same clang version, same file, on the Mac:

| bundle | `-target-linker-version` in the cc1 line | undefined symbols of the object | link through `ld64.lld` |
|---|---|---|---|
| `be33328d1c99` | 1053.12 | `_objc_msgSend$length`, `_objc_msgSend$stringWithUTF8String:` | links, runs |
| `8d7d908f2630` | 1267 (m1m's `ld-1267`) | `_objc_msgSend$length`, `_objc_msgSendClass$stringWithUTF8String:$_OBJC_CLASS_$_NSString` | undefined symbol |
| `8d7d908f2630` with `-mlinker-version=811.2` | 811.2 | as the first row | links, runs, thin LTO too |

msc links a macOS build with the bundle's `ld64.lld`, so it now states that linker's version (`BUNDLE_LD64_VERSION`,
`selectNativeToolchain`): 811.2, the newest gate of the driver that `ld64.lld` 23.1.4 serves. The link line is the
same with and without it; the driver already decides the link arguments by the linker being lld.

Rejected: `-fno-objc-msgsend-class-selector-stubs` in the compile flags. It names the one feature, but the driver
reports it unused on every C and C++ file (`argument unused during compilation`, an error under `-Werror`).

The matrix had no Objective-C consumer. Cells `objcCompanion` and `objcRelease` (`matrix/objcCompanion.m`, two class
messages, `-framework Foundation`) fail with the installed msc `c62ba752f7de` and bundle `8d7d908f2630`, debug and
`--release`, and print `matrix-objc 8` on a candidate of tree `b11227f36240` on m1m for macos-arm64, bundle and zig alike.
macos-x64 through the bundle links both; its debug cell dies loading the missing x86_64 runtime dylib like every
debug cell of that target, and zig finds no `Foundation/Foundation.h` for it.

Not done: the engine still bakes its build machine's linker version (a hidden input of the producer); a driver that
decided the stubs by the linker being lld would need no number, and that is a source edit for the next engine round.

## Measured 2026-11-13 — a debug build guards its stack frames, as under `zig cc`

zig gives every module of a debug build that links libc `-fstack-protector-strong --param ssp-buffer-size=4` and
every other build `-fno-stack-protector` (`src/Module.zig`, `stack_protector`; `src/Compilation.zig`, the C
arguments; zig `16d31ceed5`). A debug build through the bundle now passes the same pair on Linux and macOS
(`debugStackProtector`, `src/compiler/cc.ms`). A wasm build is forced to release and has none.

The matrix cells `stackSmash` and `stackSmashOff` (`tools/managedToolchain/matrix/stackSmash.c`) write 24 bytes
past a 16-byte buffer: the first must die, the second, built with `--passC=-fno-stack-protector`, must print both
lines. A candidate of tree `9a6f8501e62b`, exit status of the run (negative is a signal):

| target, run on | bundle, protected | bundle, off | zig, protected | zig, off |
|---|---|---|---|---|
| linux-glibc-x86_64, rtx (`3a7e411898f0`) | -4 | survives | -4 | survives |
| linux-musl-x86_64, rtx | -11 | survives | -11 | survives |
| macos-arm64, m1m (`8d7d908f2630`) | -6 | survives | -5 | survives |
| macos-x64 under Rosetta, m1m | not a result: no x86_64 runtime dylib loads | the same | -4 | survives |
| windows-x64, d87 (`44950a26db3f`) | not passed, see below | survives | -1073741819 | survives |

The first form of the fixture wrote 8 bytes past the buffer and survived under zig and the bundle alike on glibc,
musl, Windows and macOS x64: the guard is not adjacent to the buffer there. A slack that was an array (`long[8]`)
survived on macOS arm64 too, because a strong protector treats every array as one to keep beside the guard.

Windows is not protected yet. clang's MinGW driver adds `-lssp_nonshared -lssp` to the link of a protected
build, and no installed bundle has them: every debug cell of windows-x64 failed with `lld: error: unable to find
library -lssp_nonshared` (rtx, m1m and d87 alike) until the flag was withheld there. mingw-w64 13.0.0 keeps
`__stack_chk_fail` and `__stack_chk_guard` in `libmingwex.a`, so the two libraries are empty archives, which is
what a clang-based mingw-w64 toolchain installs. The Windows runtime producer now writes them and links a
`-fstack-protector-strong` executable and DLL as part of its check: rtx, engine `5f03abdf2cf1`, `producer rc=0
after 63 s`, and the overlay differs from the one in the installed bundles only by the four archives (8 bytes each,
for the executable and the DLL directory) and the receipt.

The other debug consumers (`hello`, `threads`, `cCompanion`, `cppCompanion`, `sharedLibrary`, `ubsanDefault`)
pass as before with the protector on. Run rows ok, the two cells above included: glibc 16, musl x86_64 14, macOS
arm64 16; musl arm64 builds all eight.

Not verified: a protected Windows program (no bundle carries the new overlay; msc passes the flag there once one
does); musl arm64 and Linux arm64 run; the cost of the guard in a debug build. Left as it is: a `--release` build
on macOS keeps clang's own default protector (frames with a character array of 8 bytes or more), which zig turns
off; the default bundle build measured 0.99 to 1.03 of zig's time there with it.

## Measured 2026-11-13 — a host build compiles for this machine's CPU

A build through the bundle that names no OS, CPU or musl now passes `-march=native` (`-mcpu=native` on arm64)
ahead of `--passC` (`hostCpuFlags`, `namesTarget`), which is what zig did for the same build: it got no `-target`
and resolved the detected host. A build that names its target keeps the driver's baseline. All numbers are a
candidate of tree `78c032900602` built by msc `1b493b622aca`, through bundles whose configs name no CPU: rtx
`3a7e411898f0`, m1m `8d7d908f2630`, d87 `44950a26db3f`.

The CPU cc1 receives, from `CC_PRINT_OPTIONS` on `tools/managedToolchain/matrix/hello.ms`:

| build | rtx | m1m | d87 |
|---|---|---|---|
| no target, debug and `--release` | `znver5` | `apple-m1` | `skylake` |
| `--release --passC=-march=x86-64-v3` (`-mcpu=apple-m1` on m1m) | `x86-64-v3` | `apple-a14` | `x86-64-v3` |
| `--release --cpu=x86_64` (`arm64` on m1m) | `x86-64` | `apple-m1` | `x86-64` |
| `--release --os=linux --cpu=x86_64 --abi=musl` | `x86-64` | `x86-64` | `x86-64` |

Speed of the built program on rtx, the default build against `--cc=zig`, `src/bench/iter/bench.ms`, second run of
each binary, us/op, gates running on the host:

| row | zig `--release` | default `--release` | zig `--danger` | default `--danger` |
|---|---|---|---|---|
| indexed for int32[] | 2.268 | 2.228 | 1.049 | 1.036 |
| for-of keys() | 1.775 | 1.856 | 13.787 | 13.205 |
| generator | 0.877 | 0.835 | 0.817 | 0.648 |
| map toArray | 18.737 | 30.121 | 4.758 | 4.338 |
| geometric mean of bundle over zig, 16 rows | | 1.03 (worst 1.61, best 0.94) | | 0.93 (1.06, 0.78) |

The same three rows were 15.4 to 17.7, 38 to 74 and 5.2 us/op under the pinned config.

`map toArray --release` is slower than zig's on rtx every time it was taken (28.860 against 19.251 us on
2026-11-12; 30.121 against 18.737, 28.426 against 18.365 and 29.289 against 22.167 on 2026-11-13), and only there:
d87 gave 56.865 against zig's 185.082 and m1m 67.424 against 59.444 under load. What it is not, measured on rtx
with msc `1b493b622aca` and bundle `3a7e411898f0` (load average 75):

- Not a flag: with `-fno-omit-frame-pointer` 29.785, with `-O3` 37.988, with `-march=znver4` 50.643 (spreads 15 to
  28 %); without LTO both are several times slower (zig 83.898, bundle 102.255); `--danger` is level (5.359
  against 5.480).
- Not the kernel: `strace -c` counts 14 `mmap` calls in the whole run under zig and 22 under the bundle, one
  `munmap` each, and `/usr/bin/time` shows 0.00 s system time for both.
- Not different code in the row's own function: the closure (`dollarfn_anon_35___benchOms_u0`, 450 and 449
  disassembly lines) calls the same 12 routines, has the same vector loops, and its map-and-push loop is the same
  instruction sequence with other registers, `%rsp` in place of `%rbp` offsets and different padding before it.
  Both call `memcpy` and `memset` in libc through the PLT.

The quiet follow-up below isolates instruction placement with a padding-only counterfactual. These earlier
flag and syscall controls, taken under load, do not independently establish its cause. Hardware counters remain
unmeasured: `perf` is closed to users on rtx (`perf_event_paranoid` 4), and that restriction was not changed.

The m1m and d87 tables of this run are not usable. m1m gave `--release` 1.18 and `--danger` 0.99 while two jobs of
the measuring session shared its cores; with `--passC=-mcpu=native`, which compiles the same code, it was 0.99 the
day before. On d87 zig's own rows moved between the two days by 2 to 10 times (`indexed --release` 8.965 then
4.932 us, `map toArray --release` 2,026.643 then 185.082), and the ratio went from 0.42 to 1.26.

The marker `-DMSC_HOST_CPU_<digest>` that keys the caches is in [BUILD-CACHE.md](BUILD-CACHE.md) §Rules. The digest
is taken in the compiler's own process (`runtime/core/hostCpu.h`) from what LLVM 23.1.4 reads to resolve `native`
(`llvm/lib/TargetParser/Host.cpp`): on x86-64 cpuid leaves 0, 1, 7.0, 7.1, 0xd.1, 0x14.0, 0x19, 0x1e.1, 0x24.0,
0x80000001, 0x80000008, 0x80000021 and XCR0; on Apple arm64 `hw.cpufamily` alone (it has no feature detection
there). Linux aarch64 reads `/proc/cpuinfo` and Windows arm64 `IsProcessorFeaturePresent`; neither is read yet, no
bundle exists for those hosts, and a host build there is refused naming `--cpu`.

Rejected: asking the bundle's clang (`clang -### -march=native`) on every build. It took under 5 ms on rtx and 38
to 172 ms on the Mac under load (a `sysctl` process took 45 to 99 ms in the same minute), against 0.19 s for a
warm `msc build` of a hello world on that Mac. Keeping its answer in a memo does not help: whatever tells that
the memo is still about this CPU is already the key.

A default `--danger` self-build through the bundle links thin LTO on macOS and Windows, where `zig cc` cannot
(`ltoBroken`). msc `1b493b622aca`, `msc build src/index.ms --danger` against the same with `--lto=off`, then
`check src/index.ms` by each result, three runs, the first cold:

| | build, LTO | build, `--lto=off` | cc1 lines with `-flto=thin` | check by the LTO binary | check by the other |
|---|---|---|---|---|---|
| m1m, bundle `be33328d1c99`, load 8 | 88 s | 72 s | 590 of 591 | 9.1, 6.39, 6.23 s | 9.32, 6.84, 6.69 s |
| d87, bundle `44950a26db3f` | 197 s | 125 s | 584 of 585 | 15.15, 12.22, 11.96 s | 16.12, 13.19, 12.7 s |

On the Mac (M3 Max, installed bundle `8d7d908f2630`, msc `1b493b622aca`) `hello.ms` and `cppCompanion.ms` build and
run in debug and `--release`, and `hello.ms` builds and runs with `--sanitize=address`, `thread` and `undefined`,
linking `libclang_rt.asan_osx_dynamic.dylib`, `tsan_osx_dynamic` and `ubsan_osx_dynamic`; `--cc=zig
--sanitize=address` fails at link there (`undefined symbol: ___asan_handle_no_return`).

Tests of `src/compiler/toolchain.ms` and `cc.ms` by the candidate: exit 0 on rtx and m1m. On d87 `msc test` exits
127 for every file under the installed msc as well (inbox card `2026-11-12-msc-test-exits-127-on-windows.md`); the
test binaries it left, `_test_toolchain_*.exe` and `_test_options_*.exe`, exit 0 run by hand.

Not verified: a quiet host for any speed row; `-mcpu=native` on the M3 Max in a benchmark (it reads `apple-m3`
there); a cache restored on another machine; a host build on Linux aarch64 or Windows arm64; `--cc=zig`, which
detects the CPU itself and carries no marker.

## Measured 2026-11-13 — the old toArray gap depends on instruction placement

On rtx (Ryzen 9 9950X), tree `fbae860ba8d2b44510ce5face8ac28b0dcaf2275` of this slice before the checked-store
block transform, bundle `3a7e411898f0`, a HEAD-matched candidate built by `260e884307c5` compiled
`src/bench/iter/bench.ms` through each driver. Each arm had its own working directory and `MSC_CACHE_DIR`,
with `MSC_NO_GLOBAL_CACHE=1`. All 20 emitted C files were byte-identical within each zig/bundle pair.
Three rounds in a `run-remote.sh --host rtx --quiet 8` window reversed arm order in the middle round:

| map toArray, us/op | zig | bundle |
|---|---|---|
| release, median of three process medians | 17.083 | 27.163 |
| danger, same method | 4.130 | 4.248 |

The release closure's scalar map/store loop has the same instruction sequence in both binaries: 34 bytes,
including the overflow branch and backedge. Its start is at offset 0 modulo 64 in zig's binary and offset 32
in the bundle's. A counterfactual moves only that loop into the seven bytes of NOP padding immediately before
it. It preserves every instruction and call, fixes the overflow branch's relative displacement, retains the
backedge target, and fills the vacated bytes with NOPs. No function, data, symbol or subsequent instruction
moves. Two rounds in reverse order, in a separate quiet window:

| release binary | loop start modulo 64 | median us/op |
|---|---|---|
| original bundle | 32 | 27.048 |
| same placement, rewritten NOPs | 32 | 27.053 |
| moved 1 byte earlier | 31 | 27.348 |
| moved 2 bytes earlier | 30 | 20.214 |
| moved 4 bytes earlier | 28 | 16.844 |
| original zig | 0 | 16.814 |

Thus instruction placement alone recovers the old gap on this program and CPU. This does not identify a
particular cache or front-end counter event; none was measured. The patched binaries are experimental controls,
not a compiler fix. No debug information, alignment flag or binary patch was added to the shipped build path.
Local evidence: `out/toArray-{quiet,layout-quiet}.remote.log`, `out/toArray-trace-quiet-evidence/` (C and assembly),
and `.probe/toArrayLayout.py` (asserts the changed byte range and both branch targets).

The alignment mechanism is **SAME**, not a semantic divergence to record in NIM-REF. The bundle's LLVM 23.1.4
sets preferred x86 loop alignment to 16 (`llvm/lib/Target/X86/X86ISelLowering.cpp`, `setPrefLoopAlignment`, line
2870); `getPrefLoopAlignment` at 64731 only overrides innermost loops for an explicit experiment.
`llvm/lib/CodeGen/MachineBlockPlacement.cpp:3033-3109` applies that preference to hot loop blocks. The observed
zig binary also aligns this loop to 16; its placement within 64 bytes is not a stronger loop-alignment contract.
Zig source read: `16d31ceed5de91b469e010b4a8d515236ad6bf14`, `src/Compilation.zig` `addCCArgs`, including its
frame-pointer choice at 6707. The drivers' frame-pointer/debug-info and libc-target differences remain real;
the padding-only control holds those differences fixed rather than attributing the gap to one of them.

After rebasing onto main `8260059f7778`, tree `5dbe85359e153c0967caf2b09f7d2265e68561be` includes the existing
checked-store block transform (`3b06018ad364`). A fresh candidate through the same bundle, without extra
compiler flags, gives the following in another quiet window (09:23:26-09:27:48Z, cap 8 minutes), three rounds
with reversed arm order in the middle round:

| map toArray, us/op | zig | bundle |
|---|---|---|
| release | 7.484 | 6.218 |
| danger | 4.078 | 4.065 |

All 20 emitted C files are still identical within each driver pair. Candidate owner tests: `cc.ms` 216/216,
`toolchain.ms` 152/152; `check src/index.ms` exits 0. Local evidence: `out/toArray-postM2-quiet.remote.log`,
`out/toArray-trace-postM2quiet-evidence/`. The original gap is absent on this native-CPU tree; a global alignment
change is not justified by the old loop. No single main commit is isolated as the cause of that improvement.

This is not a full parity verdict: across all 16 rows the bundle/zig geometric means are 0.927 in release and
0.965 in danger, but release `keys()` is 1.510/1.331 us (bundle/zig), release `zip product` 1190.053/1059.012,
and danger `eager map filter reduce` 66.332/63.119. Those remain audit rows, not accepted regressions; a good
mean does not close them. Not verified here: post-transform baseline x86-64, other CPUs/hosts, or a general
alignment policy.

### Follow-up controls on the same native-rtx source

Tree `8c94cc14be2b54979896129123f14e20a252bea8` changes only the measured documentation relative to the
post-M2 source above. Each of the following controls used a separate quiet window and three reversed-order
rounds. They are experiments, not default flags or binary patches in the build path.

Matching frame-pointer policy does not close release `keys()` or `zip product`. Each flip keeps all 20 C
files and their cache paths, and the generated prologue is asserted to change in the requested direction:

| release, us/op | zig default | zig omit FP | bundle default | bundle keep FP |
|---|---|---|---|---|
| keys | 1.355 | 1.355 | 1.554 | 1.562 |
| zip product | 1073.163 | 1084.564 | 1235.199 | 1203.948 |

Zig `Module.zig:214-225` defaults to keeping FP; `Compilation.zig:6707` forwards it. Evidence:
`out/tail-fp.remote.log`, `out/tail-fp-evidence/`, `.probe/tailFpTrace.sh`. Danger had occasional process
outliers above 2x even during this admitted window; those results are not a parity certificate.

A separate keys control pins every arm to CPU 6 (sibling 22). It changes only a 144-byte vector loop and its
preceding NOP padding, leaving code/data outside that region fixed. Register/flag dependencies, the backedge
and absence of other entries into the loop are asserted; two bad reorderings fail the dependency check.

| keys release, us/op | bundle | reordered bundle | moved 4 bytes earlier | reordered and moved |
|---|---|---|---|---|
| median | 1.570 | 1.586 | 1.297 | 1.294 |

Zig is 1.380 us. Reordering alone does not recover the gap; the padding/placement control does. This keys
experiment did not separately measure rewritten NOPs at unchanged placement, so it does not isolate their
encoding from the shift or identify a hardware-counter mechanism. The unchanged zip code remains about
1210 us against zig's 1083. Evidence: `out/keys-schedule.remote.log`, `out/keys-schedule-evidence/`,
`.probe/keysSchedule.py` and `.probe/keysScheduleTrace.sh`.

The link pipelines also differ: actual tiny-C driver plans show clang 23.1.4 release passing
`-plugin-opt=O2`, while zig 0.16.0 passes `--lto-O3` for both `-O2` and `-O3`. Zig source at the revision above,
`src/link/Lld.zig:883-888`, selects that level. `out/lto-plans.remote.log` records both plans.

A link-level-only control keeps front-end `-O2`, all 20 C files/paths and all 174 cached object inputs fixed.
Explicit LTO O2 reproduces the default binary's text exactly. On CPU 6:

| release, us/op | bundle LTO O2 | bundle LTO O3 |
|---|---|---|
| zip product | 1204.505 | 1022.829 |
| indexed for int32[] | 1.160 | 1.567 |
| keys | 1.566 | 1.586 |
| map toArray | 6.322 | 6.391 |
| eager map filter reduce | 70.595 | 72.545 |

Zig's zip is 1098.190 us. LTO O3 alone closes that row, but loses 35% on indexed relative to bundle O2;
this is not evidence to flip the fleet default. Text grows from 62828 to 64988 bytes. The 16-row bundle/zig
geometric mean barely changes (0.9269 to 0.9245), again hiding a per-row trade-off. Evidence:
`out/lto-level.remote.log`, `out/lto-level-evidence/`, `.probe/ltoLevelTrace.sh`.

Not verified by these controls: compile/link cost of a level change, other hosts/CPUs or baseline targets,
and source changes after this tree. A rebase needs fresh program evidence before any policy change.

## Measured 2026-11-12 — the source-built engine against the installed engines

`tools/managedToolchain/llvmEngine.cmake` builds the engine the way LLVM's own releases are built:
`clang/cmake/caches/Release.cmake` with `LLVM_RELEASE_ENABLE_PGO` (stage1 → stage2-instrumented trained on
`clang/utils/perf-training` → stage2 with the profile and ThinLTO). A single plain `-O3` stage was tried first and
rejected: on m1m its cc phase took 31.6 s against 24.6 s for the upstream release engine (one run, loaded host).

Each A/B runs one msc (built from tree `acf4b6737caf` on rtx and m1m, `915af4044166` on d87) against two bundles that
differ only in the engine, the installed one and the source one, three reps, alternating arms, in a `run-remote --quiet`
window; foreign load is the CPU the rest of the host used meanwhile. Seconds are wall; CPU is the build's own.

| host (installed engine) | foreign | cold self-build `--lto=off` | thin-LTO self-build | 39-object cold build | edits | produced msc |
|---|---|---|---|---|---|---|
| rtx x86_64-linux (plain source engine) | < 2 cores (last two reps) | 54-55 / 61-65 s, CPU 266 / 336 s | 56 / 58 s | 4.2 / 4.6 s | equal | equal |
| m1m aarch64-macos (upstream LLVM-23.1.4-macOS-ARM64) | 1.3-2 cores | 78.8-79.7 / 78.3-78.5 s, CPU 232 / 232 s | 87.6 / 87.1 s | 5.90-5.99 / 5.35-5.49 s | equal | equal |
| d87 x86_64-windows (upstream MSVC release) | 0.4-1.5 cores | 127.7-129.3 / 125.1-125.6 s, CPU 541 / 515 s | 149.0 / 143.7 s | 7.51-7.57 / 7.40-7.51 s | equal | equal |

Compressed size (`tar | xz -6`) of the bundle with the source engine against the installed one: rtx 37.2 / 66.7 MB,
m1m 28.8 / 107.5 MB, d87 54.0 / 207.2 MB. Each source bundle passes `platformMatrix.ms` on its host, and its msc
builds a g2 that checks `src/index.ms` clean.

What the numbers carry:
- Small C compiles are 10% slower on m1m. Upstream's training is C++ (perf-training builds LLVMSupport);
  `CLANG_PGO_TRAINING_DATA_SOURCE_DIR` can add msc's emitted C to it, untried.
- The Windows engine is built with mingw-w64 and libc++, because d87 has no MSVC. Upstream's Windows release sets
  `LLVM_ENABLE_RPMALLOC`, which needs the static MSVC CRT (`llvm/CMakeLists.txt` at llvmorg-23.1.4, the
  `LLVM_ENABLE_RPMALLOC` and `LLVM_INTEGRATED_CRT_ALLOC` blocks), so the mingw engine runs on the UCRT heap; the 2-5%
  above is that difference plus the build.
- On first use per global cache msc hashes every manifest entry (`verifyBundlePayload`, `src/compiler/toolchain.ms`),
  so a Windows bundle whose 26 tool names are hardlinks of one 101 MB `llvm.exe` hashes 2.6 GB once per machine:
  24.5 s against 13.5 s on d87. The A/B warms each arm's stamps before its cold cells for that reason.

Traps of the source build, each fixed in `sourceEngine.ms` or the cache:
- perf-training's `llvm-support/build.test` runs `cmake -G Ninja` and finds ninja on PATH, so the producer puts the
  given ninja first on PATH.
- On an arm64 Mac the engine stage's universal sanitizer dylibs fail `lipo` (x86_64 and x86_64h, "same
  architectures"); LLVM's release workflow (`.github/workflows/release-binaries.yml` at llvmorg-23.1.4, issue 99767)
  builds compiler-rt for arm64 alone there, and so does the producer.
- Windows: Git's GNU tar reads `C:` as a remote host without `--force-local`, and cannot create the symbolic links
  the source carries (test inputs and mlgo-utils scripts the build never reads; the release bat extracts with 7z).
- Windows: `CLANG_ENABLE_BOOTSTRAP` switches its next stage to clang-cl, so the Windows stages follow
  `llvm/utils/release/build_llvm_release.bat` (instrument, train on Sema.cpp, merge, final) as separate builds; in-tree
  compiler-rt needs `LLVM_BUILTIN_TARGETS`/`LLVM_RUNTIME_TARGETS`, since `COMPILER_RT_DEFAULT_TARGET_ONLY` conflicts
  with the triple the runtimes build passes.

Fixed in the source the engine is built from (`LLVM_SOURCE_EDITS`, `tools/managedToolchain/sourceEngine.ms`): in a
multicall build clang re-ran itself as `clang.exe clang.exe -cc1`, so every out-of-process job (an `.S` assemble)
failed "unknown argument: '-cc1'". At llvmorg-23.1.4 `llvm/tools/llvm-driver/llvm-driver.cpp` `MakeDriverArgs` hands
clang a non-null PrependArg when NeedsPrependArg is false, and `clang/tools/driver/driver.cpp` set it whenever
canonical prefixes are on; a POSIX symlink canonicalizes to `llvm`, which makes the prepend right there, while a hard
link or a copy named clang resolves to itself. LLVM main still has `|| CanonicalPrefixes` in `driver.cpp`. The edit
prepends only when the resolved executable is not the one invoked (their stems differ). With it, on d87 and on rtx, a
hard-linked and a copied `clang`/`clang++` assemble an `.S` and compile with `-fno-integrated-cc1`, rc 0 with and
without `-no-canonical-prefixes`; the symlinked `clang`, `clang++` and `x86_64-linux-gnu-clang` on rtx and
`llvm clang` on both keep working (`.probe/winPatchVerify.sh`, `.probe/linuxPatchVerify.sh`, final stage rebuilt
incrementally, 19 s and 14 s). Not verified: macOS, and an engine built by the whole producer from the edited source.

## Measured 2026-11-12 — musl and wasm32-wasi runtimes from source, in every host's bundle

`tools/managedToolchain/prepareTargetRuntime.ms` builds one target's runtime from pinned upstream source with the
engine's clang and writes an overlay of bundle paths in LLVM's per-target layout (`runtime/<name>` as the sysroot,
`lib/clang/<major>/lib/<triple>`, `lib/<triple>`, `include/c++/v1`, `include/<triple>/c++/v1`), so a config is
`-target`, `--sysroot` and, on Linux, `--rtlib=compiler-rt` and `--ld-path`. `assembleBundle --overlay` adds
overlays to an engine and a runtime bundle. Sources: wasi-libc `wasi-sdk-34`, musl 1.2.5, Linux 6.19 headers,
compiler-rt, libunwind, libc++abi and libc++ of LLVM 23.1.4 (`targetRuntime.ms` holds the URLs and digests).

On rtx, one bundle of the PGO engine, the installed glibc runtime and the three overlays (216 MB, 44.3 MB as
`tar | xz -6` against 66.7 MB installed), a candidate msc of the tree, `platformMatrix.ms --compilers=bundle`:

| target | built | ran ok on rtx | zig (same day) |
|---|---|---|---|
| linux-glibc-x86_64 | 16 | 16 | 17 built |
| linux-musl-x86_64 | 16 | 14 | 17 built, 14 ran ok: its TSan cell builds and fails when run |
| linux-musl-arm64 | 16 | not run (no arm64 host in the run) | 17 built |
| wasm32-wasi | 15 | 13 (node) | 15 built |

Not built by the bundle: ASan on every target and TSan on musl (no library; zig has no ASan either), the three
`--sanitize` cells on glibc (the installed runtime has no sanitizer libraries, see below), C++ on wasm32-wasi (zig
fails it as well; wasi-sdk carries three LLVM patches for it).

The wasm32-wasi overlay is 232 files. Two producer runs on rtx in different work directories gave the same bytes
for all of them. A run on d87 (the engine rebuilt with the multicall fix) and one on rtx gave the same bytes for the
231 files other than the receipt, after three host differences were removed in the producer: empty archives
(`llvm-ar` writes the host's format when an archive has no member), a header cmake writes with CRLF on Windows, and
host paths in the receipt. Producer wall: 16 to 41 s on rtx, 63 s on m1m, 284 s on d87, 6 to 8 cores. Not verified:
the receipt and the m1m bytes after the last producer change, a musl overlay built on macOS, and musl on Windows
(refused there: musl and the Linux headers build with make and sh).

Traps met:
- `assembleBundle` copies the engine's runtime libraries under each Linux config triple, which replaced an
  overlay's musl builtins with the engine's x86_64 glibc ones (the aarch64 cells failed "incompatible with
  aarch64linux"); overlays are now added after that copy.
- libc++abi's check for `__cxa_thread_atexit_impl` passes on any target when cmake try-compiles a static library,
  so a C++ `thread_local` with a destructor failed to link on musl until `LIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF`.
- The `ubsanRelease` cell compared the value a signed overflow in a C companion prints: `-2147483648` with
  `--lto=off`, `2147483648` under the default LTO, with the installed msc and the candidate alike. It now checks
  only that a release build does not trap.
- msc passed `-target wasm32-wasi` itself, which overrode the config's `wasm32-wasip1`; a wasm build now names no
  target when the bundle config owns it (`cliCompileFlags`, `cliLinkFlags`, `src/compiler/cc.ms`).

The Linux engine rebuilt by the whole producer from the edited source took 1906 s on 16 cores of rtx beside two
gates. With the installed runtime it is bundle `e447dbf8b746`: 37.2 MB against 66.7 MB, `platformMatrix`
linux-glibc-x86_64 cells ok, self-build through it g1 159 s and g2 94 s (not a quiet window), g2 checks the
compiler clean.

## Measured 2026-11-12 — ASan and TSan on musl build, and run only in a dynamic executable

compiler-rt of LLVM 23.1.4 against the musl 1.2.5 overlays, compiled by the bundle's clang on rtx (bundle
`541eae252989`: PGO engine, installed glibc runtime, musl and wasi overlays). `clang_rt.asan`, `asan_static`,
`asan_cxx`, `tsan` and `tsan_cxx` build for `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl` with no
failed step. A C program with a heap overflow (`-fsanitize=address`) and one with a data race
(`-fsanitize=thread`), linked three ways and run on rtx through the sysroot's `libc.so` as the loader:

| link | ASan | TSan |
|---|---|---|
| `-static` (msc's musl executable) | link fails: `undefined hidden symbol: _DYNAMIC` | the same |
| `-static-pie` | links, segmentation fault at startup (exit 139) | the same |
| dynamic | reports `heap-buffer-overflow`, exit 1 | reports `data race`, exit 66 |

A musl build of msc is static, so `--sanitize=address` and `--sanitize=thread` on `--abi=musl` are refused by name
with the bundle (`muslSanitizerGap`, `src/compiler/toolchain.ms`); `--sanitize=undefined` builds and runs. zig
fails the ASan cell at link (`undefined symbol: __asan_memcpy`) and builds a TSan executable that fails when run.
Not verified: the aarch64 programs were linked, not run; C++ under either sanitizer; a dynamic musl executable
on a musl system (Alpine) instead of through the sysroot's loader.

On rtx the installed msc gives `error: link failed` for both, a candidate of the tree gives
`error: native toolchain: --sanitize=thread is not available on linux-musl: its runtime needs a dynamically linked
executable and a musl build is static, zig cc fails it as well`, and the matrix rows of both musl targets read
`n/a (bundle refuses…)` in place of `FAIL`: 16 built and 14 ran ok on x86_64, 16 built on arm64, as before.

A wasm build dropped `--sanitize` without a word: `cliCompileFlags` returns for `--os=wasm` and bare wasm32
before the flag is added, so `--sanitize=undefined` on `ubsanCompanion.ms` built and printed the wrapped
`-2147483648` with no report, with zig and with the bundle alike (the `ubsanSan` cell failed when run, the three
`san*` cells passed without a sanitizer). msc now refuses it for either compiler (`wasmSanitizerGap`,
`src/compiler/cc.ms`): `error: --sanitize=undefined is not available on wasm: a wasm build links no sanitizer
runtime.` The wasm32-wasi cells are then 11 built and 10 ran ok for zig and for the bundle, the four sanitizer
cells `n/a (msc refuses…)`, the C++ companion the one `FAIL` of both. This replaces the 15 built and 13 ran of
the table above, which counted the four `--sanitize` cells as built and the three `san*` ones as run.

## Measured 2026-11-12 — the Windows engine by its producer, one `llvm.exe` under 26 names

On d87, from `llvm-project-23.1.4.src.tar.xz` with the source edit above, the first stage compiled by bundle
`07b7c1d8410a` (installed engine, mingw runtime, C++ runtime from source); msc `d7cb5337a11f` ran the producer and
`e3f94f82fda4` the rest; the tools are those of tree `89879ca7e6a1`:

- `prepareSourceEngine --bundle` runs the four Windows stages (stage0 with its builtins and profile runtime, an
  instrumented clang, the `Sema.cpp` training compile, the engine with the merged profile):
  `producer rc=0 after 3518 s` at `--jobs 8`, beside this arc's own test jobs. The build trees take 12.5 GB (stage0
  2.1, instrument 3.3, train 0.2, final 4.4, source 2.5); the profile is 43,377,376 bytes from one `.profraw`.
- `llvmEngine.cmake` configures the engine stage alone on a Windows host. Its cache elsewhere is unchanged: an empty
  project configured with the file before and after gives the same 126 cache entries (cmake 4.2.3, macOS).
- The install holds `llvm.exe` (101,354,496 bytes) as 26 copies, 2.5 GB: LLVM installs a tool alias with
  `cmake -E copy` unless `LLVM_USE_SYMLINKS` is on, which defaults to `CMAKE_HOST_UNIX` (`llvm/CMakeLists.txt`,
  `llvm_install_symlink` in `llvm/cmake/modules/AddLLVM.cmake`). `packageSourceEngine` stores the names of `bin/` that
  have the same bytes as one file: `pkg 112M, bin 97M, files 329, names in bin 26, links of llvm.exe 26`; its tar is
  116,817,920 bytes, 29,502,520 at `xz -6`. Packaging took 50 s on the idle host and 543 s beside the engine build,
  because every name is hashed three times (7.9 GB).
- The engine imports ADVAPI32, CRYPT32, KERNEL32, ntdll, ole32, SHELL32, VERSION, WINHTTP and the Universal CRT's
  `api-ms-win-crt-*` sets; the package audit takes those sets as system libraries and refuses any other DLL.
- In a measurement bundle (bundle `07b7c1d8410a` with this package's `bin/` and resource headers, resealed, 413 MB,
  never installed), `platformMatrix.ms` builds 16 of 16 windows-x64 consumers and 31 run rows are ok. The one FAIL,
  `debugLine debugstop` (`gdb: no stop at debugLine.ms:3`), is the same row with the installed engine: the harness
  asks gdb, the build carries CodeView. `g1 through the bundle: 150 s`, `g2 by g1: 65 s`, and g2 checks
  `src/index.ms` with no type errors in 584 modules.
- msc installs a bundle of hard-linked tools: with `MSC_TOOLCHAIN_ARCHIVE` naming a 52,412,456-byte `tar.xz` of that
  bundle (written by `C:\Windows\System32\tar.exe`, bsdtar 3.8.4) and no bundle in a fresh home, the first build
  extracted, verified and used it in 75 s (`installed: links of llvm.exe 26, size 413M`), and the second build took
  4 s.

Not measured: a compile-time A/B of this engine (the table above measured the same stages run by hand), ThinLTO for
the Windows engine (the stage is PGO alone, as in the release bat), a Windows arm64 host, and the m1m and rtx engines
rebuilt with this cache file. The next section assembles a bundle from this package.

## Measured 2026-11-12 — what `zig cc` does on a host build, and a bundle whose configs name no CPU

Since `303df0be8582` made the bundle the default compiler, a host build ran several times slower than under
`zig cc` (rtx, `src/bench/iter/bench.ms --release`, us/op: indexed 15.4-17.7 against 2.0, `keys()` 38-74 against
1.77, generator 5.2 against 0.85; session iter-fusion). The cause is the CPU, not the compiler: with no `-target`
zig compiles for the detected host CPU (`lib/std/zig/system.zig:365`, zig `16d31ceed5`), and msc gave zig no
`-target` for a host build. The glibc config of a bundle carried the cc1 line zig prints for a cross target, one
`-Xclang -target-cpu x86-64` and 189 `-Xclang -target-feature` lines, and the Windows config one
`-Xclang -target-cpu`. Options given through `-Xclang` reach the compiler after the driver's own, so every build
was x86-64 with SSE2 and a `--passC=-march=native` changed nothing (rtx, installed bundle `e447dbf8b746`: the
assembly of a file with and without `-march=native` is identical).

What the same msc build passes to the compiler under `--cc=zig` and under the installed bundle, read from
`CC_PRINT_OPTIONS` on `hello.ms` and `cppCompanion.ms` (msc `1b493b622aca`; rtx bundle `e447dbf8b746`, m1m
`be33328d1c99`, d87 `95dae1a75e7b`):

| | `zig cc` | bundle |
|---|---|---|
| CPU of a host build | rtx `znver5`, 85 features on; d87 `skylake`, 57; m1m the detected model, 92 | rtx and d87 `x86-64`; m1m `apple-m1` (no config on macOS) |
| `--danger` | `-O2`: zig maps `-O1`, `-O2` and `-O3` to one mode and passes `-O2` (`src/main.zig:2334`) | `-O3` |
| `--release` LTO | none on macOS and Windows | thin on all three |
| frame pointer, release | kept (`-mframe-pointer=all`; `non-leaf` on macOS) | `none` (`non-leaf-no-reserve` on macOS) |
| debug info, release | DWARF 4 (CodeView on Windows) | none; `hello --release` on rtx is 34,656 bytes against 250,008 |
| stack protector | strong in a debug build, off in release | off on Linux and Windows; clang's basic one in every mode on macOS |
| debug UBSan runtime | zig's, with recovery | compiler-rt's minimal one (standalone on Windows and musl) |
| glibc of a host build | the host's (rtx: triple `gnu2.43.0`, the program needs `GLIBC_2.34` to `2.36`) | 2.31 (the program needs `GLIBC_2.17`) |
| link, Linux | `EXEC`, `BIND_NOW`, RELRO, `PT_GNU_STACK` size 16 MB, no build id | the same |
| main-thread stack, Linux | 8 MB: the kernel takes it from `ulimit -s` (8192 on rtx) and ignores the 16 MB `PT_GNU_STACK` size zig writes (`link/Lld.zig:221`, `-z stack-size`) | the same |
| main-thread stack, macOS | 16 MB (`LC_MAIN` `stacksize 16777216`, zig's own linker, `link/MachO.zig:184`) | 8 MB (`stacksize 0`): `ld64.lld` 23.1.4 warns `-stack_size is not yet implemented` and drops it |
| main-thread stack, Windows | not measured | 16 MB, `-Xlinker --stack=16777216` (`windowsConfig.ms:92`) |

Main-thread stack, measured with a non-tail recursion `down(n)` (`1 + down(n - 1)`, about 76 bytes a frame at `-O0`; msc `c62ba752f7de`; one run each, depth 150000 unless noted). macOS bundle link: `LC_MAIN` `stacksize 0`, segfault (139); the same binary under `ulimit -s 16384` returns 150000 and 190000; `--cc=zig` on `hello` links `stacksize 16777216` (the run was not made). Linux rtx, bundle and `--cc=zig`: `readelf -lW` shows `GNU_STACK … 0x1000000 RW` and both segfault. Windows d87 bundle: returns 150000. So the default Linux and macOS links crash on a program Windows runs, and the `PT_GNU_STACK` size is no main-thread stack.

Bit-fields are laid out the Windows way by zig and by both d87 bundles (a `_Static_assert` on
`struct { char a : 4; int b : 4; }` being 8 bytes), although only zig's cc1 line names `-mms-bitfields`.

The config renderers now write no CPU and `assembleBundle` drops the pin from a copied runtime's configs. Without
it the driver picks `-target-cpu x86-64` itself and the predefined macros are the same (sha256 of `-dM -E`
`c01e5ce48a66` both ways); the baseline's tuning becomes clang's generic one (`incq` where the pinned config gave
`addq $1`, which `-mtune=x86-64` reproduces); `-march=native` gives `znver5` and a later `-march=x86-64-v3` wins.

Speed of the built program, `--cc=zig` against a bundle assembled by this tree with `--passC=-march=native`
(`-mcpu=native` on arm64), time of bundle over zig as the geometric mean of the 16 rows of
`src/bench/iter/bench.ms`, second run of each binary, hosts not quiet:

| | rtx (Ryzen 9 9950X) | m1m (M1 Max) | d87 (i7-8700K) |
|---|---|---|---|
| `--release`, host CPU | 1.01 (worst row 1.50, best 0.92) | 0.99 (1.09, 0.93) | 0.42 (0.76, 0.02) |
| `--danger`, host CPU | 0.98 (1.06, 0.80) | 1.03 (1.06, 0.99) | 0.80 (1.14, 0.15) |
| `--danger` with `-O2` | 1.06 (1.76, 0.81) | 1.29 (2.20, 1.01) | 0.81 (1.17, 0.14) |
| `--release`, baseline against `zig cc -mcpu=baseline` | 0.94 (1.16, 0.47) | 0.99 (1.04, 0.89) | 1.15 (1.80, 0.36) |

The worst release row on rtx is `map toArray` (28.860 against 19.251 us; 4.375 against 4.200 in `--danger`). On d87
`map toArray --release` is 44.798 us against zig's 2,026.643.

The bundles of that table, each assembled from an engine package, the host's installed runtime where it has one
and the same four overlays (Windows with its C++ runtime, wasi, musl x86_64 and aarch64), with `platformMatrix.ms`
from its host under msc `1b493b622aca`:

- rtx `3a7e411898f0`: 454 MB, 14,555 files, 64,535,792 bytes at `xz -6` (installed: 37,227,908). linux-glibc-x86_64
  16 built, 29 run rows ok; linux-musl-x86_64 16 built, 28 run rows ok; linux-musl-arm64 16 built; wasm32-wasi 11
  built, 20 run rows ok; windows-x64 16 built from Linux. FAIL: the four glibc sanitizer cells (the bundle ships no
  ASan, TSan or standalone UBSan for glibc) and `cppCompanion` on wasi. `g1 through the bundle: 73 s`,
  `g2 by g1: 50 s`, g2 checks `src/index.ms` clean.
- m1m `8d7d908f2630`: 415 MB, 12,369 files, 55,115,900 bytes at `xz -6` (installed: 107,463,408). macos-arm64 18
  built, 35 run rows ok; macos-x64 18 built, 12 run rows ok and 21 FAIL: a debug or sanitized x86_64 program cannot
  load `@rpath/libclang_rt.*_osx_dynamic.dylib`, which the engine package and the installed bundle `be33328d1c99`
  both carry for arm64 alone; both musl targets and windows-x64 16 built; wasm32-wasi 11 built, 20 run rows ok.
  `g1 through the bundle: 78 s`, `g2 by g1: 44 s`.
- d87 `44950a26db3f`: 409 MB, 11,786 files, 54,809,776 bytes at `xz -6`, assembled in 124 s beside other jobs.
  windows-x64 16 built, 31 run rows ok; wasm32-wasi 11 built, 20 run rows ok; both musl targets 16 built. FAIL:
  `cppCompanion` on wasi and the `debugstop` cell (gdb on a CodeView build). `g1 through the bundle: 164 s`,
  `g2 by g1: 107 s`.

The Windows C++ runtime is now part of the Windows overlay: `prepareWindowsRuntime` builds libc++, libc++abi and
libunwind after the C runtime and links a C++ executable and DLL as its check (`producer rc=0 after 60 s` on rtx,
222 MB, 5,304 files; the C part differs from the overlay before only in the two configs and the receipt). The
archives are 3,648,592, 719,490 and 89,596 bytes against 3,648,972, 719,870 and 89,596 for the ones d87 built
with the same recipe, and the overlay also carries libunwind's headers (`runtimeCpp.cpp` includes
`libunwind.h`). `prepareCxxRuntime`, which added the runtime to an assembled bundle on d87 in 634 s, is gone.

The musl overlays keep libc++'s headers in their sysroot (`usr/include/c++/v1` and
`usr/include/<triple>/c++/v1`). They were under the bundle's own `include/`, which clang searches for every
target: on m1m a C++ build for macOS then stopped at `include/c++/v1/__config:13:10: fatal error: '__config_site'
file not found`. `assembleBundle` refuses an overlay that has `include/`.

Also measured: with d87's installed bundle `95dae1a75e7b` and msc `1b493b622`, `cppCompanion.ms --release` fails at
link (`undefined symbol: __cxa_thread_atexit_impl`, from the zig-built `c++abi.lib`); the candidate `de6e68691e8a`
passes the same matrix as above under that msc.

Not verified: msc does not pass the native CPU yet, so a default host build is still the baseline; the d87
baseline row and the rtx `map toArray` row on a quiet host; whether the object cache and the std unit store can
take `-march=native` (the text is the same on two machines); the tuning change of the baseline on a benchmark of
its own; macOS with a model newer than the default (the M3 Max reads `apple-m3` under `-mcpu=native`, m1m is the
default `apple-m1`); an install of any of the three bundles; the windows-x64 and linux-musl-arm64 programs built
on rtx and m1m run on their own hosts.

## Measured 2026-11-12 — a bundle from an engine and overlays: Windows, wasi and musl from d87

`assembleBundle` takes an engine and target overlays alone (`--runtime-bundle` is optional), because a bundle that
overlays were merged into keeps files outside `runtime/` that an engine swap would drop (d87's installed bundle: the
mingw builtins and the UBSan receipt). The overlays below were built on rtx with engine `5f03abdf2cf1` (the PGO
engine package) and shipped to d87 as one archive; the tools are those of tree `87ec6611fb48`.

- `prepareWindowsRuntime` (mingw-w64 13.0.0, archive sha256 `5afe822af5c4…`): `producer rc=0 after 54 s`, 197 MB,
  3,596 files. Its builtins are sha256 `5e878299b2b4…`, the digest of the archive built on 2026-11-08 with another
  engine build. It now builds the standalone UBSan too (`libclang_rt.ubsan_standalone.a` 1,711,710 bytes, its C++
  half 34,518), puts both in the executable and the DLL directory, and links `-fsanitize=undefined` through both
  configs as part of its check; before, only `prepareSanitizerRuntime.py` made them.
- The musl overlays (`prepareTargetRuntime`, 49 s and 46 s) no longer carry the 8 Linux headers whose name differs
  from another header only by case (`linux/netfilter/xt_CONNMARK.h`, `xt_DSCP.h`, `xt_MARK.h`, `xt_RATEEST.h`,
  `xt_TCPMSS.h`, `netfilter_ipv4/ipt_ECN.h`, `ipt_TTL.h`, `netfilter_ipv6/ip6t_HL.h`): 2,983 files on rtx became 2,975
  when the archive was unpacked on d87's NTFS, each pair reduced to whichever file was written last. zig deletes
  the same 8 (`tools/update-linux-headers.zig`, `bad_files`, at `16d31ceed5`). The overlays are now 2,975 and 2,946 files on both
  hosts, and `assembleBundle` refuses an overlay that holds two paths differing only by case.
- On d87, `assembleBundle --engine win-producer-pkg` with the four overlays: 367 MB, 8,390 files, identity
  `c5fb16e280df`, in 474 s; after contract writing, verification and tool copies hash each physical file once
  (`digestOncePerFile`, by volume and file index or device and inode) the same command takes 62 s and gives the same
  identity. `prepareCxxRuntime --target x86_64-windows-gnu` on that bundle (634 s, before that change): 392 MB,
  10,092 files, `links of llvm.exe 26`, tar 394,814,976 bytes, 53,962,164 at `xz -6` against 207,179,188 for the
  installed bundle, which carries Windows alone.
- `platformMatrix.ms` from d87 through that bundle, msc `7b6e64e1f852` named by `MSC`: windows-x64 16 built and 31
  run rows ok; wasm32-wasi 11 built and 20 run rows ok (node), `cppCompanion` the one FAIL (no
  `wasm32-wasi.cxx.cfg`; zig fails it too); linux-musl-x86_64 16 built; linux-musl-arm64 16 built; the musl
  artifacts are not run on Windows. ASan and TSan on musl and mingw and every sanitizer on wasm are refused by name.
  `g1 through the bundle: 153 s`, `g2 by g1: 66 s`, g2 checks `src/index.ms` clean (589 modules).
- The linux-musl-x86_64 programs d87 built, copied to rtx and run there by `platformMatrix.ms run`: 14 run rows ok
  and `debugstop ok` (DWARF, gdb stops at the line).
- The matrix runs the installed msc unless `MSC` names one. With d87's installed `9a9713925` every wasm32-wasi cell
  fails (`drc.h:20:10: fatal error: 'stdlib.h' file not found`: it passes `-target wasm32-wasi` beside the config) and
  the musl ASan and TSan cells fail at link instead of being refused, so this bundle needs the synced msc first.

Not verified: a compile-time A/B of this bundle against the installed one, the linux-musl-arm64 programs built on d87
run on an arm64 host, an install of this bundle and the overlays' bytes when built on another host. The Windows C++
runtime has since moved into the Windows overlay (the section above).

## Measured 2026-11-12 — what zig builds for each target, and the order of the C runtime libraries

`tools/managedToolchain/platformMatrix.ms build --compilers=zig` on rtx, msc `e21c6e7c3666`, zig 0.16.0, all nine
targets, 18 consumers each (rows kept in `out/zigBaseline-rtx.tsv` of the worktree, not in git). Only the native
target ran; the others were built, not run.

| target | built | zig fails |
|---|---|---|
| linux-glibc-x86_64, linux-glibc-arm64, linux-musl-x86_64, linux-musl-arm64 | 17 | `--sanitize=address` (no ASan runtime) |
| macos-arm64, macos-x64 | 15 | full LTO, `--sanitize=address`, `--sanitize=thread` |
| windows-x64, windows-arm64 | 15 | full LTO, `--sanitize=address`, `--sanitize=thread` |
| wasm32-wasi | 15 | the C++ companion (zig's libc++ does not compile there) |

Each installed bundle carries its own target only (read on rtx, d87, m1m and the Mac the same day), so the other
eight targets of every host still build with zig.

The glibc config of the installed rtx bundle (`8e018abb167f`, copied from a zig link line) names libm, libc, ld,
libpthread and the rest as leading linker inputs, ahead of everything the build line adds. A `--passL` library was
therefore needed after libc, and one that reaches libc through `dlsym(RTLD_NEXT, ...)` lost it
(`.inbox/compiler/2026-11-12-a-passl-library-is-linked-after-libc-so-rtld-next-interposers-lose-libc.md`).
`assembleBundle` now moves the libraries a top-level config names behind the build's inputs (`runtimeLibrariesLast`,
`tools/managedToolchain/runtimeConfig.ms`). On rtx, the `libraryOrder` and `libraryOrderShared` cells
(`--passL=-Wl,--no-as-needed --passL=-lutil`, executable and `--app=lib`):

| bundle | needed, in order | other cells of linux-glibc-x86_64 |
|---|---|---|
| installed `8e018abb167f` | libm, libc, ld-linux, libpthread, libutil | 31 ok |
| reassembled from it, PGO engine | libutil, libpthread, libm, libc, ld-linux | the same 31 ok |

The card's own repro on the reassembled bundle lists `libfoo.so` first and `libc.so.6` after it, and runs. On both
bundles `--sanitize=address`, `--sanitize=undefined` and `--sanitize=thread` fail to link on rtx: the bundle has no
`libclang_rt.asan_static.a`, `ubsan_standalone.a` or `tsan.a`. zig builds the last two. Not verified: arm64, a
bundle installed on a host, the Wings test of the card.

## Measured 2026-11-09 — a ref release disposes through one call

rtx, Linux x86-64. One g1, built from tree `9966bc7d6d35` with the host `msc`, built every arm; the arms
differ only in `runtime/`, each adding one step to the one before. The shipped steps are tree
`516f13436208`.

| arm | step | msc `.text` `--danger` | `--lto=off` | `check src/index.ms` instructions, `--danger` / `--lto=off` |
|---|---|---|---|---|
| c0 | before | 40,014,429 | 28,214,703 | 62.79G / 77.74G |
| c1 | the four decref macros call `msDestroyAndDisposeDyn` instead of the destroy dispatch and the dispose | 28,814,556 (−28.0%) | 21,079,247 (−25.3%) | −0.03% / 0.00% |
| c2 | `msDropEdgeLast` keeps its stack-room check inline and disposes through the same call | 28,408,164 (−1.4%) | 20,856,635 (−1.1%) | −0.04% / +0.05% |
| c3 | `msStringCopy` is one call | 28,229,120 (−0.6%) | 20,709,827 (−0.7%) | +0.02% / +0.01% |
| c4 | `msRegisterCycle` and `msUnregisterCycle` are `noinline` | 22,639,154 (−19.8%) | 20,708,291 (0.0%) | −0.83% / −0.86% |
| | c4 against c0 | **−43.4%** | **−26.6%** | **−0.87% / −0.81%** |

Instructions are `perf stat -e instructions:u` on a warm check, medians of 5 interleaved rounds in a
30-minute quiet window; one non-quiet round of the same arms gave the same step ratios within
0.03%. Hello world `--danger --strip` `.text`: 17,139 → 16,411 B. `src/bench/collections`
`.text` 96,634 → 84,898 B, `src/bench/json` 168,778 → 127,030 B.

Wall time, the same window, each arm's row against c0's in the same round (median of the 5 per-round
ratios): over the 30 bench rows and the two checks, the geometric mean is 0.994 for c4. The slowest
rows are `Map set/get string 10k` 1.056 (rounds 0.66 to 1.60) and `map/filter 10k` 1.026 (0.97 to
1.04), against a round-to-round spread of 58% and 7.5% for c0 itself; `check` is 0.988 at `--danger`
(0.95 to 1.00) and 0.977 at `--lto=off` (0.61 to 1.77). Step c1 alone was slower on `json parse strings 64 KB` in every round (1.17, 1.08
to 1.36); c4 is 0.990 on the same row. That the c1 row is code placement in the parse loop, which
calls no release, is a guess, not measured.

Why a release site was big: msc's emitted C has about 146k generic release sites (92,767
`msDecrefCyclic`, 53,491 `msDecref`), and each expanded the destroy dispatch and the whole dispose
(unowned check, cycle-root unregister, slab free) inline. The reference inlines only the last-ref
check and calls the rest (`nimDecRefIsLast` inline, `nimDestroyAndDispose` a call); `rememberCycle`
is `noinline` there. Under LTO the two cycle-root calls, reached only when a root is added or
removed, were inlined into every cyclic decref; `noinline` takes 5.6 MB off and the instructions go
down, because the inline copies cost more in the instruction cache than the rare call.

Rejected, each against its parent arm in the same runs:
- `msRememberCycle` out of line whole, as the reference does: `.text` −12.8% / −1.2%, instructions
  **+4.2% / +5.9%**, because every cyclic decref then pays a call even when it registers nothing.
- `msOrcTraceRef` with only the null check inline: `.text` −1.8% / −2.1%, instructions **+0.87% /
  +0.72%** (the reference keeps `nimTraceRef` inline too).
- `msDropEdgeLast` out of line whole: −1.8% / −1.4%, instructions **+0.20% / +0.15%**; the split in
  c2 keeps the size and not the cost.

Pinned by `src/test/guard/releaseDisposeOutOfLine.ms`. Not measured: macOS and Windows sizes, other
hosts' wall time, and Nim's static split for final types (a direct `=destroy` plus a raw dispose, two
calls and an alignment argument per site, so larger than one call; not built).

## Rejected and parked 2026-11-09 — what remained after one out-of-line release call

rtx, Linux x86-64; arm d0 is main `155b7f913a1`, d1 adds the step; one g1 of main built both.

What a site of each remaining op costs, `-O3` arm64, in a `noinline` wrapper: `msDecrefCyclic` 33
instructions, `msAllocTyped` with a constant size 15 (a call and three stores), `msVariantAccess`
14 and `msArrayAccess` 10 (the check inline, a call only on the error), `msIncref` 6. None carries a
slow path inline any more, so none was split further.

Rejected on 2026-11-09, then shipped on 2026-11-10 (next section): a release site leaves a last
ref's cycle-root unregister to `msDestroyAndDisposeDyn`, which does it before the destroy (Nim's
acyclic `nimDecRefIsLast` unregisters nothing; its cyclic `rememberCycle` unregisters before the
destroy and its dispose does not repeat it). In one code layout it is smaller, runs fewer
instructions, and is slower in wall time:

| | d0 | d1 | d1 / d0 |
|---|---|---|---|
| msc `.text` `--danger` | 22,666,018 | 21,569,676 | −4.8% |
| msc `.text` `--lto=off` | 20,732,503 | 19,652,659 | −5.2% |
| `check src/index.ms` instructions `--danger` / `--lto=off` | 62.24G / 77.13G | 62.05G / 76.81G | −0.31% / −0.42% |
| `check` wall, `--lto=off`, 5 rounds | 6,845–6,897 ms | 6,952–6,995 ms | +1.5%, every round |
| `Set add/has 10k` | | | 1.048 (1.025 to 1.110) |
| `json stringify strings 64 KB` | | | 1.030 (1.011 to 1.050) |
| `join 10k strings` | | | 1.029 (1.017 to 1.044) |

A 15-minute quiet window at load 0.6 to 1.1; rows are the median of the 5 per-round ratios against
d0 in the same round, the range in brackets. `check` at `--danger` was 1.001. The slower rows include
string parse, stringify and join loops that release no reference, and the json bench binary grew by
1.3 KB while its release sites shrank, which points to code placement rather than the moved
unregister; the next section measures that reading.

Rejected 2026-11-10 after it was unblocked: a function's last `return` parks its value and falls
into the finally that releases its locals, instead of emitting a second copy of that finally (Nim
emits the copy: `blockLeaveActions` at every return; `easyResultAsgn` handles only a first-statement
return). Its M1 abort was the analyzer counting every view local of `genFunctionDecl` once the step
stored a view into a `Cursor<Readonly<Node>>` field; fixed on main `fcb27e4fedd`. m1m (M1 Pro), arms
are two compilers built by one g0 of `fcb27e4fedd`, each building the same source, 8 ld64 layouts ×
2 rounds per arm, load median 1.40:

| | d0 | d1 (the step) | d1 / d0 |
|---|---|---|---|
| msc `__text` `--danger` | 19,405,392 | 19,113,404 | −1.50% |
| msc `__text` `--danger --lto=off` | 17,185,444 | 16,891,764 | −1.71% |
| hello `__text` `--danger --strip` | 3,872 | 3,872 | 0 |
| `check src/index.ms` instructions | | | +0.61%, d1 above every d0 layout (spread 0.1–0.2%) |
| `check` cycles, round 1 / round 2 | | | +0.45% / +0.33% |
| 28 bench rows | | | geomean 0.998, every row overlaps |

The cost is the shared epilogue: the normal path now runs the finally's `if (msErr) goto BeforeRet_`
that the copy returned before, one TLS-flag load and branch per return through a finally, because
after one shared finally body the code must tell the raise path from the normal one. Pinned while it
was built by `tailReturnFinallyEmit.ms` (red 3/3 without, green 3/3 with); the step and its pin are
`~/metascript/.wt/handoff/runtime-dce-tailreturn.patch` and `runtime-dce-tailReturnFinallyEmit.ms`.

## Rejected 2026-11-11 — link ICF, and emitting C only for the functions a program reaches

rtx (Linux x86-64, the prepared `ld.lld`) and m1m (M1 Pro, the prepared `ld64.lld`); builder
`63cca29efba8` (tree `293ff251b1f4`) building the `runtime-dce` worktree of that day, whose tree
was not recorded. One build per arm, then the same objects linked again per mode, so the sizes are
exact and no time below is an A/B.

**Link ICF**, `--passL=-Wl,--icf=<mode>`, the compiler's own text section:

| mode | Linux `.text`, thin LTO | Linux, `--lto=off` | macOS `__text`, thin LTO | macOS, `--lto=off` |
|---|---|---|---|---|
| none | 18,816,034 | 17,121,038 | 17,357,924 | 16,098,372 |
| `safe` | 18,645,906 (−0.90%) | 16,517,678 (−3.52%) | 17,191,236 (−0.96%) | 16,098,372 (0) |
| `all` | 17,624,882 (−6.33%) | 16,134,222 (−5.76%) | 16,111,716 (−7.18%) | 15,063,108 (−6.43%) |
| `safe_thunks` (ld64 only) | | | 16,214,612 (−6.59%) | 15,231,260 (−5.39%) |

`all` is refused because it changes what `===` answers. A program holding two named functions with
the same body and two arrows with the same body, each compared with `===`, counts 4 distinct
functions without ICF and under `safe`, and 2 under `all`, on both platforms and in both LTO modes.
`safe` keeps identity through the address-significance table: every one of the 583 Linux objects of
the `--lto=off` build carries `.llvm_addrsig`, no macOS object carries `__llvm_addrsig`, hence the 0.
It was not taken for 0.9% of the shape a release ships; the 3.5% of Linux `--lto=off` (2,920 folded
sections, 579,431 B) is a shape no release ships. A small program gains less: the JSON bench
94,192 → 94,112 B under `safe` with thin LTO on Linux. The macOS identity probe ran on the
development Mac. Not measured: run speed under any mode (the Linux `all` compilers pass
`check src/index.ms`), identity under `safe_thunks`, Windows.

**Emitting C only for reached functions** would not shrink a binary: every object has one section
per function and the link drops the unreached ones, so hello's link keeps 5 of the 375 functions
its 14 generated C files define, and 13 of those files contribute nothing. What it could save is
the compile of those files, and that is bounded by `phase.C` (emit and compile of C) on a build
that restores no object. Three cold builds without the global object store, rtx on 8 cores, load
rising from 3.7 to 45 during the run:

| program | `phase.setup` + `phase.graph` + `phase.A`, share of total | `phase.C` | `phase.C` warm |
|---|---|---|---|
| hello, 13 modules | 81–90% of 4.5–12.0 s | 338–1,831 ms | 42–76 ms |
| JSON, 28 modules | 78–83% of 9.0–12.1 s | 1,303–2,346 ms | 99–129 ms |

With the global object store primed by one hello build, a fresh project's hello spends 155–207 ms
in `phase.C`, and ten corpus programs each restored 11–12 std modules and compiled 0–2. So the
saving exists only on a build that finds no stored object, where the front end is four fifths of
the wall. Not measured: the saving itself (nothing was built), and macOS.

## Measured 2026-11-10 — the root unregister leaves the release site, over randomized layouts

The 2026-11-09 slowdown is code placement. In a `perf record` of `check` on rtx, `msStringConcatArr`,
the same source and size in both arms, took 0.56–0.77% of cycles in d0 and 1.65–2.55% in d1, only
its address different; with `-falign-loops=32` it was 0.70% in both. `Map set/get int 10k`'s
`Map_set` is byte-identical in both arms (1,609 B) and its row still moved 8%. So each arm is now
built in several link orders and an arm is slower only when it is slower than every layout of the
other.

| host, layouts | d1 / d0 |
|---|---|
| rtx, 4 per arm (`lld --shuffle-sections`, clang, `-ffunction-sections`, `--lto=off`), load 2.0–2.4, arms of main `155b7f913a1` | `check` cycles 0.998, wall 1.001; 30 bench rows geomean 1.005; `json parse large 1 MB` 1.042, beyond every d0 layout, the rest overlap |
| m1m (M1 Pro), 8 per arm (ld64 `-order_file` of the shuffled text symbols, globals and statics), 2 rounds, load median 1.54, arms of main `155b7f913a1` | `check` round 2 cycles 0.993; 28 bench rows geomean 0.999, every row overlaps; `json parse large 1 MB` 0.999 |
| m1m, the same recipe, arms of main `60ecbc206ed`, load median 1.52 | `check` round 2 cycles 0.990 and wall 0.989, d1 below every d0 layout; instructions 1.0005; 28 bench rows geomean 1.000, every row overlaps; `json parse large 1 MB` 0.995 |

m1m `__TEXT` of msc `--danger --lto=off`: 18,530,304 → 17,498,112 B (−5.6%); the bench binaries
keep their page-rounded size. Round 1 of `check` is left out: the first run of each binary did more
work (73.7G against 71.0G instructions, both arms), so only round 2 is warm.

`array slice 10k` and `array spread 10k` (each copies and frees an 80 KB array) are bimodal per run,
whatever the layout: fast 1.45 / 0.90 µs, slow 4.6 / 3.1 µs. Over 10 rounds of 4 layouts per arm
the slow mode came up in the same share of runs (`spread` 24/40 d0, 23/40 d1; `slice` 11/40, 8/40),
with the same fast-mode medians and the same page reclaims per run in both modes, so the two rows
are left out of the geomean above; their cause is not measured.

Pinned by the unregister rows of `src/test/guard/releaseDisposeOutOfLine.ms`: red on the d0 runtime
of `60ecbc206ed` (`msDecref`, `msDecrefAny`, `msDecrefCyclic` reference `msUnregisterCycle`), green
on d1, macOS arm64. Not measured: Linux x86-64 over 8 layouts (rtx stayed loaded) and Windows.
Fixed loop alignment for every program (`-falign-loops=32`, +1.1% `.text` at `--lto=off`) would make
single-layout runs comparable; it stays off by default (the person, 2026-11-10), and layout-randomized
runs are the measurement instead.

## Measured 2026-11-12 — `--strip` drops the unwind tables of a Linux build

Decision (the person, 2026-11-12): only a `--strip` build drops them. `stripUnwindFlags` in
`src/compiler/cc.ms` adds `-fno-asynchronous-unwind-tables -fno-unwind-tables` to the compile flags
when the target is Linux (gnu or musl), `--strip` is given and no `--sanitize` is; every other build
compiles as before.

rtx, Linux x86-64; old = the compiler of tree `e9d81b35dc9e`, new = a candidate of that tree with the
change; each cell is `msc build <program> <mode> --strip`, file size in bytes. `.text` is
byte-for-byte the same size in every pair, and every pair printed the same output with the same
exit code. The programs are those of §Measured 2026-11-12 — what small programs link, plus an
iterator-helper program (`src/test/corpus/programs/iteratorHelpersMatchNode.ms`) and one that
catches an `Error` and then ends on an unhandled one.

| program | `--danger` old → new | `--release` old → new | default (`-O0 -g`) old → new |
|---|---|---|---|
| hello | 8,960 → 8,384 (−6.4%) | 8,960 → 8,384 | 51,568 → 48,688 |
| Map/Set/array | 39,728 → 36,704 (−7.6%) | 40,304 → 37,120 | 228,832 → 217,296 |
| JSON | 104,432 → 97,408 (−6.7%) | 104,096 → 96,528 | 546,200 → 523,112 |
| strings | 59,528 → 56,488 (−5.1%) | 57,704 → 54,520 | 229,496 → 217,992 |
| two awaits in an async function | 56,192 → 51,520 (−8.3%) | 54,304 → 49,616 | 262,112 → 243,712 |
| the same awaits at the top level | 68,760 → 62,792 (−8.7%) | 67,272 → 61,192 | 291,928 → 271,464 |
| iterator helpers | 112,456 → 104,120 (−7.4%) | 107,864 → 99,640 | 513,928 → 496,632 |
| caught and unhandled `Error` | 27,080 → 25,224 (−6.9%) | 26,808 → 24,760 | 105,304 → 98,680 |

`.eh_frame` goes from 528–7,352 B to 52 B at `--danger` and `--release` (what the C startup objects
carry), and to about 2.4 KB in a default build, whose overflow-check runtime is linked prebuilt; a
build without `--strip` keeps its `.eh_frame` byte for byte (528–7,352 B). A static musl build of the JSON program: 132,568 → 126,064 B. The
unhandled-`Error` program still prints `Error: unhandled exception: boom 7` with the exit code it had: the
report reads the error flag and walks no stack. The installed Linux compiler (25.7 MB unstripped,
`9a9713925`) carries 1,226,740 B of `.eh_frame` and 155,892 B of `.eh_frame_hdr`, 6% of its stripped
size; it was not rebuilt with the flag.

Decision (the person, 2026-11-12): the option stays, and the compiler's own release build takes no
`--strip` on any target, because its symbols and unwind tables are useful to us when a released
`msc` crashes or is profiled (`tools/release.sh`, pinned by `tools/releaseToolchainTest.sh`). What
that keeps, rtx, a candidate of tree `dc5549071d4c` building itself `--release`, toolchain bundle
`e447dbf8b746`:

| | file | gzip -9 | `.eh_frame` + `.eh_frame_hdr` | `.symtab` + `.strtab` | `.text` |
|---|---|---|---|---|---|
| `--release` | 26,262,336 | 8,634,806 | 1,333,520 | 2,844,442 | 18,475,170 |
| `--release --strip` | 22,090,056 (−15.9%) | 7,703,778 (−10.8%) | 5,816 | 0 | 18,475,170 |

The unstripped binary type-checks the tree. Not measured: the five other release targets, and the
archive a release ships (std, runtime and vendor travel beside the binary).

What a stripped Linux binary no longer has:
- a debugger backtrace: gdb and lldb unwind an optimized frame through `.eh_frame`, and a stripped
  binary has no `.debug_frame` to fall back on;
- `perf record --call-graph dwarf` call chains (a flat profile is unaffected);
- a C++ exception that crosses a MetaScript or runtime frame: with no table for that frame the C++
  runtime calls `std::terminate`. C++ code keeps the tables of its own functions, so a throw caught
  inside the C++ it came from is unaffected. Not measured here.

Nothing in `runtime/` or `std/` reads the tables: no `backtrace`, `_Unwind_*`, `dladdr` or
`pthread_cancel` (only `__builtin_frame_address` in `runtime/drc.h`, which needs none).

Not changed, with the reason: macOS (the installed compiler's `__unwind_info` is 55,072 B of 21.6
MB, and a small program's sits inside a page it occupies anyway), Windows (`.pdata` is how x64
unwinds a hardware exception), a sanitizer build (its reports print stacks), Android (not measured).
Pinned by the inline test `--strip drops unwind tables on Linux only, and never under a sanitizer`
in `src/compiler/cc.ms`. Not measured: aarch64 Linux, gcc, and whether a debugger still walks a
stripped default build.

## Measured 2026-11-10 — LTO and size flags of `--danger`, over randomized layouts

m1m (M1 Pro), 8 ld64 layouts per arm, warm `check`, against O3 with thin LTO, the `--danger`
default. Default toolchain (no `--cc`: the prepared LLVM 23.1.4 clang and `ld64.lld`, read from each
binary's `LC_BUILD_VERSION` tool 4 version 23.1.4), source main `f43cbfb0d731`, load median 1.69:

| arm | msc `__text` | hello `__text` | `check` cycles | `check` instructions | 28 bench rows |
|---|---|---|---|---|---|
| O3 + thin LTO | 18,559,044 | 2,856 | 1.000 | 1.000 | 1.000 |
| O3, `--lto=off` | 17,106,376 (−7.8%) | 4,040 | 1.111 | 1.105 | 1.110, 16 rows beyond every LTO layout, none faster |
| `--passC=-Os` + thin LTO | 15,927,400 (−14.2%) | 2,628 | 1.058 | 1.079 | 1.074, 19 rows beyond, 2 faster |

hello is measured with the arming-hook fix (`cb6aecdae040`); without it the bundle links the async
runtime into hello (26,220 B at O3 + thin LTO).

Apple clang (`--cc=clang`), source `c147fab0083` plus `fcb27e4fedd`, load median 1.54, same recipe:

| arm | msc `__text` | hello `__text` | `check` cycles | 28 bench rows |
|---|---|---|---|---|
| O3 + thin LTO | 19,358,528 | 3,872 | 1.000 | 1.000 |
| O3, `--lto=off` | 17,143,984 (−11.4%) | 3,984 | 1.110 | 1.119, 22 rows beyond every LTO layout |
| `--passC=-Os` + thin LTO | 15,897,420 (−17.9%) | 3,316 | 1.056 (median; one layout 1.44) | 1.078, 20 rows beyond |
| `--passC=-mllvm -inline-threshold=100` + thin LTO | 19,247,040 (−0.6%) | 4,048 | 1.002 | 0.999 |

Both compilers rank the arms alike: thin LTO buys about 11% of `check` for 8–13% of `__text`, and
`-Os` costs 6% of `check`. `-Os` and `-mllvm` reach the link line too (read through a `clang`
wrapper). `array push 10k` is 3.7× slower without O3 and LTO together, on both compilers; why is not
measured. `Map forEach 10k` runs 3.6× faster at `-Os` than at either O3 arm on both compilers
(bundle 9.31–9.36 µs against 34.13–34.25, Apple clang 9.49 against 34.13–35.03, every layout); why is
not measured. Linux is not re-measured here.

Decision, 2026-11-10: release builds choose flags for run speed and dev/test builds for build speed,
size being secondary; `--danger` keeps O3 + thin LTO, `--release` keeps O2 + thin LTO, and the
default build (`msc build`, `msc run`, `msc test`) stays `-O0 -g` without LTO.


## Measured 2026-11-12 — what small programs link, and a top-level `await` without the pool

Six programs, `msc build --danger --strip`, source tree `e9d81b35dc9e` (main `e21c6e7c3666`), each built
by a compiler of that tree on its host: rtx (Linux x86-64), d87 (native Windows x86-64), and this Mac
(arm64, `__text` by `size -m`).

| program | Linux file | Windows file | macOS `__text` |
|---|---|---|---|
| `console.log("hello")` | 8,960 B | 21,504 | 3,456 |
| a `Map<string, int32>`, a `Set<int32>`, an `int32[]` with `map`/`filter`/`sort`, printed | 39,728 | 52,224 | 23,916 |
| `JSON.parse<Point>` of a literal, one field changed, `JSON.stringify` | 104,432 | 115,200 | 65,160 |
| `split`, `toUpperCase`, `replace`, `join`, `indexOf`, a `float64` and an `int32` in a template | 59,528 | not measured | 28,976 |
| two `await`s of a `setTimeout` promise inside an `async function` | 56,192 | 65,024 | 39,540 |
| the same two awaits at the top level | 68,760 | 73,216 | 48,956 |

A top-level `await` linked the thread pool although it spawns nothing: `msWaitForReady` calls
`msPoolRunEdge`, `msPoolCompensate` and `msPoolCompensateEnd`, each of which called `msPoolGet()`,
whose first call starts the workers, and `msPoolCompensate` names `msPoolStartThread`. On macOS the
pool functions only the top-level form linked sum to 8,200 B (`msPoolWorkerLoop` 2,064,
`msPoolCompensate` 1,484, `msPoolRunQueued` 1,232, `msPoolRunEdge` 1,160, six smaller). The pool now
arms its two wait operations when it starts (`msPoolWaitsArmed` in `runtime/promise/pool.c`), the
idiom of `msArmExitDrain`, and a wait that finds none armed has no pool to help or compensate:

| top-level `await` program | before | after |
|---|---|---|
| Linux file / `.text` (rtx) | 68,760 / 47,771 B | 56,136 / 38,027 B |
| macOS `__text`, installed compiler with the changed runtime beside it | 48,956 | 38,484 |

The hello and async-function programs keep their bytes (8,960 and 56,192 B on Linux). The spawn and
top-level-await corpus programs (17, among them `spawnWaitRunsOnlyItsEdge`,
`spawnResolverLeafOnManyWorkers`, `spawnEdgeLessPileUpFailsLoud`, `spawnTimerWaitStartsNoSpare`,
`topLevelAwaitOfTimerStartsNoPool`) passed three rounds of 58 cells on that candidate, and 16 of 17
under SAN with the one recorded xfail. Pinned by the `topLevel` program of
`src/test/guard/asyncTimerLinksNoPool.ms`. Not measured: the Windows size after the change.

What the arming costs a program that starts the pool: an armed operation is linked whenever the
pool is, called or not. `405-lockedSharedCounter` and `406-arcSharedBox` never block in `msWaitFor`
or `msWaitForReady`, the only callers of `msPoolCompensate`, and now keep `msPoolCompensateStart`
and `msTimerFiresHere`: 406 at `--danger` on Linux goes from 78,408 to 78,904 B and from 64 to 69
atomic instructions (rtx, one candidate of tree `b4816069bf94`, the pool source of `98d433dae402`
against that tree's). `400-actorHeapStr` and `409-awaitStructActorSpawn`, which do block, keep their
Linux counts (152, 156) under the new function names. Arming through two pointers instead of one
table kept both functions (406: 78,928 B, 69), so the table stays. The `@maxatomics` budgets of the
8 budgeted programs are re-recorded on both hosts; on darwin the pool source before the change was
not run, so its moves (406: 183 → 221) are not split between this change and earlier drift.

Wait latency, `src/bench/compiler/programs/spawnFanout.ms` at 20,000 spawns × 20 per run, the same
candidate with both pool sources, 7 interleaved rounds on rtx at load 37–40, wall ms old / new:

| case | median | fastest | slowest |
|---|---|---|---|
| `fan` | 271 / 271 | 247 / 248 | 411 / 399 |
| `words` | 404 / 445 | 256 / 263 | 451 / 501 |
| `nested` | 607 / 538 | 381 / 367 | 867 / 917 |

The arms overlap in every case and one arm spreads up to 2.5×, so this shows no difference and
resolves none under about that spread; a quiet host was not taken. What the wait loops execute
more is one atomic load per `msPoolCompensate`, and per `msPoolRunEdge` only while tasks are
pending, each followed by an indirect call where a direct one was.

Windows hello carries 12,662 B of `.text` against 3,662 on Linux with no event loop in either; its
`.pdata` counts 25 functions of the mingw CRT, 13 of the statically linked winpthreads and 14 of the
runtime and the program. The split, from the link map of that build (d87, the compiler of
`e3f94f82fda4`): mingw CRT 5,170 B (`pseudo-reloc`, `crt2`, `pesect`, `tlsthrd`), winpthreads 2,766
(`mutex.o` and `misc.o`; about 3.2 KB with their data and unwind rows), the runtime 3,317, the
program 381. What brought winpthreads in, and the hello without it (17,920 B), is in §Measured
2026-11-12 — a Windows hello links no winpthreads.

## Measured 2026-11-12 — a library exports only its API

A shared library keeps every symbol it exports, and a library build exported nearly all of std and
the runtime: every module-level `export`, generic instance, type info and runtime C function had
default visibility. A library build (`--app=lib`, `--app=staticlib`, not `--hcr`) now compiles
with `-fvisibility=hidden -DMS_LIB_BUILD` (`src/compiler/cc.ms` `LIBRARY_HIDES_INTERNALS`) and
marks what a host calls `MS_LIB_EXPORT` (`runtime/core/export.h`): the project's `@exportName`
functions, `MsMain`, `MsDestroyGlobals`, each module's `__DatInit000` and `__Init000`, and
`msDrainAtExit` and `msReportOrphanFailures`, the two exit calls of the `main` an executable gets.
An `@exportName` inside std pins a C name for the runtime and a constructor carries one
internally; neither is exported. A C source the project compiles with `@compile` keeps the
visibility it declares (`foreignSourceFlags`), because a host may load it by name
(`tools/managedToolchain/matrix/sharedLibrary.ms`). The reference hides every routine and exports
only one marked for the library and its `NimMain` (`lib/nimbase.h` `N_LIB_PRIVATE` and
`N_LIB_EXPORT`, `compiler/ccgtypes.nim` `genProcHeader`, Nim `15dd34468`; a one-proc library built
by Nim 2.2.2 on macOS exports 3 symbols, `__text` 17,308 B). The module inits and the two exit
calls are ours: `docs/BARE.md` and `tools/crypto/x25519Build.sh` call an init by name, and the
reference has no exit drain.

`--danger --strip --app=lib`, the compiler of `c62ba752f7de` against a candidate of tree
`4af66098dd51`, file bytes and exported symbols:

| library | Linux (oci-u) | macOS arm64 (m1m), `__text` | Windows (d87) | Android arm64, NDK 28 (m1m) |
|---|---|---|---|---|
| one `@exportName` function adding two `int32` | 365,080 → 10,576, 739 → 31 | 214,480 → 4,040, 738 → 31 | 301,056 → 17,408, 801 → 31 | 315,528 → 18,864, 746 → 32 |
| one that fills a `Map` and prints, with a top-level print | 378,968 → 30,696, 791 → 35 | 223,856 → 19,516, 790 → 35 | 314,368 → 37,376, 856 → 35 | not built |

The 31 are the function, the four host calls and 26 module inits. With only the function,
`MsMain` and `MsDestroyGlobals` as link roots the first Linux library is 7,536 B, and 8,448 B with
the module inits too (the installed compiler, `--passC=-fvisibility=hidden` and one `-Wl,-u,` per
root), so keeping the inits callable costs about 900 B. A host loads the second library with
Python's `ctypes`, calls `MsMain`, the function, the two exit calls and `MsDestroyGlobals`, and
gets its output, on Linux and Windows; the guard does the same wherever `python3` exists. A static archive linked into a
host's own shared library (Linux, `--lto=off`, system `cc`) exports 20 symbols where it exported
558. `tools/crypto/x25519Abi.sh`, whose C and C++ hosts link a static archive and call two inits
by name, passes on the candidate. An executable keeps its size: hello 8,480 and
`console.log("done", 15, 2.5)` 34,440 on Linux, hello's `__text` 3,456 on macOS; `MS_LIB_EXPORT`
is empty without `-DMS_LIB_BUILD`.

The Android link passes no `--gc-sections` of ours (`cliLinkFlags`), and adding it by hand moves
the first library from 18,864 to 18,728 B, so none was added. Pinned by
`src/test/guard/libraryExportsOnlyItsApi.ms`. Not measured: a Windows executable's bytes after the
change, a Windows static archive (its entry points are declared `dllexport`), FreeBSD and iOS, a library that keeps vendored C (that C's exports and what they reach
stay, as in the reference), and run speed.

## Measured 2026-11-12 — a static build without the libc formatter

Where libc is linked statically, one `fprintf` links its whole formatter: in a static musl hello,
stdio and printf were 12,510 B of 27,455 B of sized symbols (`printf_core` 7,663, the `strerror`
table 1,914), all of it through one call, the owner-violation report `msUnregisterCycle` inlines.
A program that allocates reaches 8 more reports, an async one 6 more. The runtime's reports now
go through `msErrorf` (`runtime/core/errorf.h`), which is `fprintf(stderr, …)` where libc is
dynamic and its own 1,293 B writer (`runtime/core/system.c`; the runtime's formats use only
`%s %d %ld %lld %lu %llu %p %.*s`) on WASI and musl. rtx, old = the compiler of `e3f94f82fda4`,
new = a candidate of tree `9d52061d018f`, `--danger --strip`, file bytes:

| program | glibc, dynamic | musl, static | WASI |
|---|---|---|---|
| `console.log("hello")` | 8,480 → 8,480 | 24,992 → 13,056 | 25,848 → 7,321 |
| `console.log("done", 15, 2.5)` | 36,328 → 36,328 | 55,872 → 57,152 | 45,247 → 26,730 |
| a `Map`, a `Set` and an array, five values printed | 32,576 → 32,576 | 52,016 → 53,280 | 47,407 → 28,860 |

Each glibc pair is byte-identical. In that table the two musl programs that allocate grew by the
writer and kept the formatter, because `runtime/allocator.c` still called `fprintf` in two
reports. With those two through `msErrorf` as well (rtx, 2026-11-12, one candidate of tree
`7a33ff261e89` building each program against `runtime/allocator.c` without and with the two calls
converted, `--danger --strip`, file bytes; the starting sizes differ from the table above because
`main` moved between the two measurements):

| program | glibc, dynamic | musl, static | WASI |
|---|---|---|---|
| `console.log("hello")` | 8,480, same bytes | 13,056, same bytes | 7,321, same bytes |
| `console.log("done", 15, 2.5)` | 34,440, same bytes | 55,280 → 42,064 | 24,843, same bytes |
| a `Map`, a `Set` and an array, five values printed | 32,640, same bytes | 53,488 → 40,272 | 29,979, same bytes |
| a `Map` and a `Set`, three values printed (the guard's) | 29,984, same bytes | 50,640 → 37,424 | 25,639, same bytes |

"Same bytes" is `cmp` of the pair. Each musl program that allocates loses 13,216 B and the
formatter's prefix table, and every glibc and musl binary printed its line. On d87, where a
Windows host cross-builds musl from its own bundle, the three lose 16,464, 16,480 and 16,480 B,
and a Windows-native pair differs in one byte, offset 129, the same byte two links of one hello
differ in. Comparing the installed compiler with a candidate instead showed glibc pairs that
differ, because 45 other commits of `main` lay between the two; the comparison above holds the
compiler fixed. Not measured: the two reports printing through the writer (a pointer the
allocator did not hand out, a remote run past the 48-bit span; neither was triggered), macOS.
With the writer on every target instead (measured first), each
glibc program grew by about 2.5 KB (hello 11,032), which is why it stays off where `fprintf` is
free. The writer against libc: compiled alone it prints the same line for every specifier above,
`INT_MIN`, `LLONG_MIN`, `ULLONG_MAX`, a NULL `%s` and a 599-byte string (development Mac); with it
on every target the 179 corpus programs that assert error output passed (843 cells, 140 xfail);
18 error programs print the same stderr and exit code as a static musl build and as a glibc one.
Pinned by `src/test/guard/helloCallsNoPrintf.ms`. Not converted: `runtime/hcr.c` and
`runtime/hcrHost.c` (host tools), bare and Solana builds. Not measured: Emscripten, a static
Windows or macOS link, WASI programs run under a WASI host (sizes only).

## Measured 2026-11-08 — what a hello world links

`console.log("hello world")`, `msc build --danger --strip`. Before = tree `3acc0d784e76`, after =
tree `63f54c80d1bf`, which arms exit, thread-exit and future-release work from the facility that
first needs it (`msArmExitDrain` in `runtime/promise/drain.c`, `msArmDeferredRelease` in
`runtime/promise/pool.c`, `msTypeInfo.decrefFn` in `runtime/types.h`).

| host | before | after | reference |
|---|---|---|---|
| rtx, Linux x86-64, file | 43,728 B | 19,720 B | C `puts`, `cc -O2 -s`: 14,464 B |
| rtx, `size` text | 39,804 | 16,155 | C `puts`: 1,368 |
| macOS arm64, `__text` | 35,264 | 12,160 | Nim 2.2.2 `-d:danger --mm:orc`: 17,608 |

Before, three paths every program reaches kept the whole async runtime live although hello runs none
of it (`-Wl,-why_live`, `--cc=clang --lto=off`): `main` called `msDrainAtExit` and
`msReportOrphanFailures` directly; the allocator's first acquire arms the thread-exit release, whose
`msThreadExit` called `msFutureReleaseFlush`; and every `msDecrefAny`, `msDecrefCyclic` and
`MS_DECREF_EDGE` called `msFutureDeferredRelease` inline. Each reached the pool, the event loop, the
selector, the actor scheduler and the completion queues. A cut of one path alone saves almost
nothing (the drain hook alone: 5 KB of `__text` in a probe, 0 B in the shipped step), because the
other two reach the same code.

This follows Nim at 15dd34468 (read there; built with the installed 2.2.2): its generated `main` is
only `NimMain(); return nim_program_result` (`compiler/cgen.nim` `genMainProcsWithResult`), exit work
is registered by the module that needs it (`lib/std/exitprocs.nim` `addExitProc`),
`afterThreadRuns` runs only the handlers registered through `onThreadDestruction`
(`lib/system/threadimpl.nim`). Nim has no
implicit exit drain; ours is NIM-REF RT-41.

What a hello world still links, and why:
- the region heap and the cycle collector (`msOrcCollect`, about 3.4 KB): the unhandled-exception
  report `msTestErrorFlag` releases the exception, whose destroy reaches `msUnownedOutlives`. Nim's
  hello links its allocator and `collectCycles` the same way: `nimTestErrorFlag` drops the cyclic
  `Exception`, which reaches `registerCycle` (`lib/system/orc.nim`).
- the thread-exit arm and its teardown (`msThreadAttach`, `msAfterThreadRuns`,
  `msRootsThreadTeardown`, about 1 KB): a thread the runtime did not
  start must release its region when it exits (ULTRALOCK M11), and the allocator cannot know which
  thread that is. Nim's `afterThreadRuns` also calls its root teardown (`nimYrcThreadTeardown`) directly rather than through a handler.
- `msDrainAtExit` and `msReportOrphanFailures` as two hook reads.

Pinned by `src/test/guard/helloLinksNoAsyncRuntime.ms`. Not measured: Windows size, Nim built from
15dd34468 (`~/projects/nim/bin` holds no compiler), and wasm/emcc, whose `main` calls
`msDrainUntilIdle` directly.

## Measured 2026-11-12 — a one-char literal links the payload table only

rtx, Linux x86-64, `msc build --danger --strip`; before = the compiler of tree `e9d81b35dc9e`, after =
a candidate of that tree with the change, both building the same four programs (their sources are
described in §Measured 2026-11-12 — what small programs link):

| program | file before | after | `.rodata` before | after |
|---|---|---|---|---|
| hello | 8,960 B | 8,960 | 192 | 192 |
| Map/Set/array | 39,728 | 37,600 | 5,400 | 3,280 |
| strings | 59,528 | 57,448 | 20,352 | 18,232 |
| two awaits in an async function | 56,192 | 54,048 | 6,112 | 3,992 |

The C emitter wrote a one-char ASCII literal as `msCharTable[c]`, an element of a 128-entry
`msString` table that points into the 128 payloads of `msCharPayloads`; the `" "` that separates
`console.log` arguments is such a literal, so nearly every program linked both tables, 4,096 B. The
literal and the `s[i]` fast path (`msStringCharAt`, `msStringAsciiChar`, `msCharTableAt`) now build
the `msString` in place, `MS_STRING_LIT(&msCharPayloads[c], 1)`, which reads no table and keeps the
payload a literal `"a"` and `"abc"[0]` share. Every program printed the same output before and after.
Self-host chain on that candidate: g2 and g3 emit 550 byte-identical C files, with 6,063 uses of
`msCharPayloads[` and none of `msCharTable[`. 15 string and char corpus programs: 90 cells pass, 15
under SAN.

That left the payload table (2,048 B) in every program with a one-char literal, the `" "` between
`console.log` arguments included. A one-char literal now names its own payload (`msCharLit<code>`,
128 objects of 16 B in `runtime/core/string.c`, each in its own data section), so the table links
only where an index reads it (`msStringCharAt`, `msStringAsciiChar`). Nothing relied on the shared
payload: `msStringEquals` compares the length, then the bytes. rtx, old = the compiler of
`e3f94f82fda4`, new = a candidate of tree `6f4abd4a9667`, `--danger --strip`, file bytes, every pair
printing the same:

| program | old | new |
|---|---|---|
| `console.log("done", 15)` | 22,248 | 20,360 |
| a `Map`, a `Set` and an array, five values printed | 32,576 | 30,720 |
| a loop over `s[i] == "o"` that prints `s[4]` and `"x"` | 22,344 | 22,536 |

A program that indexes keeps the table and adds the literals it writes. The compare loop
(`s[i] == "o"` over 88,000 chars, 20,000 rounds) is the same code in both `--danger` binaries: its
function's disassembly, addresses normalized, differs in no line, and the literal folds to
`cmpb $0x6f` in both. Its user time, 5 interleaved runs at load 22, was 1.93–2.70 s old against
2.15–2.98 s new, which identical code leaves to placement and load. Self-host on the candidate: g2
and g3 are byte-identical (22,453,296 B) and g3 emits `msCharLit` names and no `msCharPayloads[`.
14 string and char corpus programs with the 8 `@maxatomics` ones: 113 cells pass, 3 xfail, and the
string programs pass under SAN. macOS arm64, the same pair of compilers built on the development Mac:
the two-argument print's `__const` goes from 2,280 to 408 B and its `__text` from 13,200 to 13,184
(the file stays on the same page count). Not measured: Windows sizes, and the default (`-O0`) build.

Pinned by `src/test/guard/oneCharLiteralLinksNoStringTable.ms`.

## Measured 2026-11-12 — a Windows hello links no winpthreads

d87, native Windows x86-64, the prepared bundle. One candidate compiler of tree `02f0363999d9` builds
`console.log("hello")` with `msc build --danger --strip` twice: with `runtime/drc.c` and
`runtime/promise/drain.c` as they were before the change, then as they are after it, so the two files
are all that differs between the rows. Sections from `llvm-objdump -h`, the map from
`--passL=-Wl,-Map=<file>` on an unstripped build:

| | file | `.text` | `.rdata` | `.pdata` | `winpthread` lines in the link map |
|---|---|---|---|---|---|
| before | 21,504 B | 12,662 | 5,092 | 624 | 24 |
| after | 17,920 | 9,878 | 4,376 | 468 | 0 |

Both print `hello`. The cause, measured on the compiler of `7b6e64e1f852`: no function of the linked
hello calls `pthread_mutex_lock` or `pthread_mutex_unlock` (`llvm-objdump -d`), yet `mutex.o` and
`misc.o` of the static `libwinpthread` are in the file. Of the 218 cached objects of that link, two
name those symbols as undefined (`llvm-nm -u` over `out/release/.cache`): `runtime/drc.c` through
`msOrphanRootsLock` and `runtime/promise/drain.c` through `msOrphanMu`. A name in any input extracts
its archive member, and the member's code stays although the functions that named it are dropped;
why the linker keeps it was not traced. Both locks are SRW locks under `_WIN32` now, as
`msHeapRetiredLock` in `runtime/allocator.c` already was; every other platform compiles the text it
compiled before.

The primitives, on d87 with the bundle's clang at `-O2`: a lock, a counter increment and an unlock,
20 M pairs on one thread and 2 M pairs on each of four threads, six rounds over two runs, host load
not sampled:

| ns per pair | SRW lock | winpthreads mutex |
|---|---|---|
| one thread | 13.5-13.7 | 11.4-11.5 |
| four threads | 18.8-20.1 | 20.5-23.5 |

The uncontended SRW pair is about 2 ns slower. Both locks are taken when a pool worker exits
(`msRootsThreadTeardown`), at the pool join (`msRootsAdoptOrphans`) and when a failure goes unhandled
(`msAdoptOrphanFailure`, `msNoteOrphanError`, the exit report), never per operation.

The same candidate on d87 runs 12 corpus programs of those paths (`721-orphanRejectionExit`,
`799-workerExitReturns`, `workerExitHandsItsCyclesToTheExitCollect`, `workerExitFreesCycleRoots`,
`workerExitSiblingActive`, `spawnJoinsAtEveryExit`, `spawnHeldFailureUnawaited`,
`spawnHeldFailureUnawaitedAsync`, `spawnHeldTwoFailuresNoLoop`, `spawnHeldSlowFailureNoLoop`,
`spawnTimeoutReportsLateFailure`, `spawnedRejectionReleasedOnce`): 40 cells pass, 0 fail, and the
guard `workerExitAdoptsCycleRoots` is ok.

Pinned by `src/test/guard/windowsHelloLinksNoPthread.ms`, which cross-builds, so every host runs it;
through zig from Linux and macOS the same hello is 80,896 B before and 80,384 after. Not measured: a
Windows program larger than hello, the corpus and guard lanes as a whole on Windows, Windows arm64,
and whether a Windows program that uses actors, the event loop or HCR links winpthreads
(`runtime/actor/actor.h`, `runtime/promise/dispatchFull.c` and `runtime/hcr.c` include `<pthread.h>`).

## Measured 2026-11-08 — the prepared bundle becomes the default; Windows leaves zig's runtime

With no `--cc`, msc builds with the prepared clang/lld bundle every target the bundle carries a runtime for, and
with zig every target it lacks (`resolveCCIn`, `bundleCarries`, `src/compiler/toolchain.ms`). The Windows bundle's C
runtime is built from mingw-w64 13.0.0 and the compiler-rt builtins of LLVM 23.1.4
(`tools/managedToolchain/prepareWindowsRuntime.ms`), not taken from zig.

**Why the Windows runtime had to leave zig.** zig's `compiler_rt` exports `memset` on every non-C object format
(`~/projects/zig` `lib/compiler_rt.zig:155-158`, master `16d31ceed5`), and it overrides the UCRT import with a loop
that runs at about 4 GB/s: 80 KB memset 20 us under `zig cc -target x86_64-windows-gnu -O2`, 1.5 us from the UCRT
(d87, best of 5 runs of 2000 calls). The producer now refuses a runtime whose `memset` is defined anywhere but the
UCRT import library (`checkMovedSymbols`). zig had also folded winpthreads into its `zigc.lib`. In the mingw-w64 shape
it is a separate archive, so the prepared Windows link carries `-Wl,-Bstatic -lpthread` like an external clang
(`cliLinkFlags`, `src/compiler/cc.ms`).

`.probe/sliceBench.ms` (`src/bench/harness`), `--release`, d87 (i7-8700K, Windows 11), one candidate msc built
from tree `644d30375577373fcd6c9717ea54f0aae66131d2`. The same candidate builds the old zig-runtime bundle (old), the
source-built bundle (new) and scoop clang with `--target=x86_64-w64-mingw32` (clang-mingw). Two runs, us/op, spread
under 4% in every row; the host was not in a quiet window:

| row | old | new | clang-mingw |
|---|---|---|---|
| slice 10k | 22.0 / 22.0 | 2.95 / 2.93 | 2.92 / 2.92 |
| slice 100k | 230 / 231 | 38.3 / 38.9 | 37.6 / 37.9 |
| fill 10k (push growth) | 47.6 / 47.6 | 16.4 / 16.6 | 16.8 / 16.9 |

Other checks on the new d87 bundle with that candidate:
- `tools/managedToolchain/platformMatrix.ms`, windows-x64: every consumer cell passes on both the bundle and zig.
  The cells are hello, threads, crypto, the C and C++ companions, a shared library, debug info, release, danger,
  UBSan (three cells) and HCR. Full LTO passes on the bundle; zig cannot run it. The debugger-stop cell fails on
  both, because the harness drives gdb, which reads no CodeView/PDB.
- The candidate self-builds through the bundle (217 s, not in a quiet window).

Two producer runs on rtx gave byte-identical overlays.

Self-host build time, bundle against zig, from the quiet A/B of 2026-11-07/08: each step recorded the CPU the rest of
the host used. Only these summaries were kept; the per-run rows were not retained. The Windows rows predate the new
runtime, which changes how fast programs run, not how fast compiles run, and they were not re-measured:

| host | cold, `--lto=off`: bundle / zig `-g0` / zig | best working config: bundle thin / zig |
|---|---|---|
| d87 x86_64-windows | 181 / 269 / 316 s | 223 / 317 s |
| m1m aarch64-macos | 90 / 109 / 126 s | 110 / 126 s |
| rtx x86_64-linux | 53 / 56 / 77 s | 60 / 88 s |

An edit rebuild was equal on both. msc built by the bundle runs 2–11% faster. `zig cc` on Linux emits full DWARF
without `-g` (a danger msc is 221 MB against 33 MB), which is why the A/B has a `-g0` zig arm. `-O2` against `-O3`
for release differs by under 1% on all three hosts, so release keeps `-O2`.

## Measured 2026-11-12 — a JS bundle keeps only what runs

`msc build <program> --target=js` writes one file. It held every declaration of every module in the
import graph, the 51 prelude modules included: `console.log("hello")` was 329,486 B, of which
`std/meta/node` 44,153, `std/serialize/json/parser` 43,469 and `std/core/buffer/codec` 34,433. The
bundle now keeps a top-level function, class, enum or effect-free binding only when something that
runs names it.

rtx, Linux x86-64; old = the compiler of tree `e9d81b35dc9e`, new = a candidate of tree
`6a53c2abfdf1` with the change; bundle size in bytes, default mode. Every pair printed the same output with
the same exit code. The programs are those of §Measured 2026-11-12 — what small programs link.

| program | old | new | modules with anything kept |
|---|---|---|---|
| hello | 329,486 | 2,044 | 6 |
| Map/Set/array | 331,934 | 5,398 | 7 |
| JSON parse and stringify | 331,876 | 82,633 | 20 |
| strings | 330,308 | 4,892 | 6 |
| two awaits in an async function | 330,201 | 3,728 | 7 |
| the same awaits at the top level | 330,002 | 3,788 | 7 |
| iterator helpers (`iteratorHelpersMatchNode.ms`) | 395,111 | 69,157 | 7 |

hello at `--danger`: 302,089 → 2,044 B. The whole corpus built on `MSCORPUS_LANES=js,esm` with the
candidate (the `js` lane is this bundle, `esm` the `--split` tree, which is not changed): 6,637 cells
pass, 39 xfail, 8 fail. The 8 are 4 programs red on both lanes: `762-bitSetMacro` (in
`known-red.json`), `callbackReadersOnWorkers` and `readonlyMapReaders` (the old compiler refuses
them with the same checker error) and `plainObjectTrait` (same stdout mismatch on both lanes).
Source maps: for a three-line program and the JSON program, the lines holding `"start"`, `"boom"`,
`function inner`, `function msDefect`, `function parseString__` and `function appendJson__` map to
the same `.ms` file and line under both compilers (`p9map.ms:5`, `:2`, `:1`, `index.jms:80`,
`parser.ms:396`, `stringify.ms:22`), although `"start"` moved from generated line 6,376 to 80.

How it decides (`src/codegen/js/reach.ms`, `runsOnLoad` and `bundleUnits` in
`src/codegen/js/jsgen.ms`, the filter in `cmdBuildJS`):
- A unit is one top-level statement of a module, or one helper the generator adds.
- A unit runs on load, and is always kept, when it is a statement (a top-level `@emit` holding
  only function declarations is a declaration instead), a binding whose initializer has
  an effect (`hasEffect`: a call, `new`, `await`, an assignment), a class with a static block or a
  static field whose initializer has an effect, a decorated or actor declaration, anything in a
  module loaded through `import()`, or text in which a line at column 0 is not the start of a
  declaration. A function or class that opens its body at column 0 owns every line up to the next
  column-0 `}`, so a raw-JS body written at column 0 stays part of its declaration.
- Every other unit is kept when a kept unit, the bundle's `export { … }` list, the module
  evaluator or a wasm binding names one of the names it declares at column 0. Uses are read from the
  emitted text, word by word, so a name inside a string also keeps its declaration: the rule can
  keep too much and cannot drop something a kept unit spells.

The reference does this in its JS backend: a proc is generated when a symbol use reaches it
(`compiler/jsgen.nim` `genProcForSymIfNeeded`, called from `genSym`), a `const` likewise
(`genConstant`), a top-level proc only when exported, and every top-level statement and `var`/`let`
always (`genVarStmt`); Nim `15dd34468`. One difference: an unused top-level binding with an
effect-free initializer is dropped here and kept there. With the reference's rule alone the hello
bundle is about 98 KB, because the prelude declares 724 such bindings (measured on the emitted
bundle with a prototype of the rule); no program's output depends on an unread binding.

The first version kept 2,038 B in hello: three raw-JS prelude functions whose `@emit` bodies
continue at column 0, which the text rule read as statements, the `Math` class, whose literal
static fields counted as load-time work, and two top-level `@emit` blocks. The body rule and the
static-initializer rule above remove the first two (rtx, old = the compiler of `e3f94f82fda4`,
new = a candidate of tree `c420c3229b99`; six programs written for this run, each pair printing the
same under node):

| program | old | new | with the raw-block rule |
|---|---|---|---|
| hello | 2,038 | 716 | 298 |
| Map/Set/array | 5,231 | 4,596 | 4,178 |
| JSON parse and stringify | 82,556 | 82,158 | 81,740 |
| strings, with a `parseInt` | 6,638 | 6,328 | 5,910 |
| two top-level awaits, reading `Math.PI` | 3,956 | 3,200 | 2,782 |
| iterator helpers (`iteratorHelpersMatchNode.ms`) | 68,150 | 67,427 | 67,009 |

The corpus `js` lane on that candidate: 2,211 cells pass, 23 xfail, 4 fail, the four programs red on
main. The 716 B were the buffer module's top-level `@emit` (a `new DataView` binding and four
functions in one statement) and `const HashMap = Map; const HashSet = Set;`. The last column is a
candidate of tree `c5e5537f4c7b` (same host and old compiler): a top-level `@emit` whose text is only
function declarations is read as a declaration (`declaresOnlyFunctions` in
`src/codegen/js/reach.ms`), and the buffer block is split into its binding and its functions. The
corpus `js` lane on it: 2,211 pass, 23 xfail, the same 4 fail. hello's 298 B are the header, the
two aliases and the `DataView` binding: raw bindings, whose initializers the filter cannot judge.
For comparison, esbuild `--bundle --tree-shaking=true` over the unfiltered
hello bundle leaves 307 B and over the unfiltered JSON bundle 78,410 B (same output under node).

Not changed: the `--split` module tree (`msc build --target=js --split`, `msc run`/`msc test
--target=js`), which a bundler or node consumes module by module.

Bundles with `@wasm` functions, macOS arm64, emcc 5.0.5, a candidate of tree `932d18079eb6`:
`src/test/wasmmix/check.sh` is green, its 8 unit modules pass (194 tests) and all 100 wasmmix
programs pass (the same stdout in each column a program names: all-C, all-JS, mixed, tree); `scalars`'s
all-JS bundle is 4,621 B and its mixed bundle 13,878 B beside an 18,791 B `.wasm`. Not measured:
those bundles' sizes before the change, wasmmix on Linux (rtx has no installed emcc, and no gate
lane runs it), build time of the filter, and bundles of the sibling repositories.

Pinned by `src/test/guard/jsBundleKeepsOnlyWhatRuns.ms` and the inline tests of
`src/codegen/js/reach.ms`.

## Measured 2026-10-29 — the native toolchain bundle against managed zig

Self-host `msc build src/index.ms` (450 modules) on RTX (WSL2, 24 threads, pinned to 16 CPUs,
load 3–11, quiet window 18:03–18:42Z), main `02a74bee6d`, candidate built `--danger --lto=off`.
Bundle `bundle-san` (IDENTITY `1d44338580b1`, clang 22.1.8, lld) against managed zig 0.16.0
(clang 21.1.0). A fresh `MSC_GLOBAL_CACHE_DIR` and `MSC_CACHE_DIR` per cell; cold = both empty,
warm store = a new local cache over the cold run's store. Three reps, zig and bundle order
alternated, median [min–max] in seconds, phases from `-t`:

| mode | cell | zig wall | bundle wall | zig cc phase | bundle cc phase | zig link | bundle link |
|---|---|---|---|---|---|---|---|
| debug | cold | 83.6 [82.5–101.2] | 60.8 [56.2–69.4] | 36.8 | 12.0 | 3.0 | 0.34 |
| debug | warm store | 54.4 [42.4–68.6] | 47.7 [42.7–53.6] | 4.7 | 2.2 | 3.4 | 0.39 |
| danger | cold | 119.5 [114.8–146.9] | 101.5 [96.6–104.1] | 82.7 | 50.5 | 0.52 | 0.24 |
| danger | warm store | 47.6 [42.9–48.7] | 49.6 [44.1–49.6] | 3.2 | 2.6 | 0.52 | 0.24 |

A build with nothing changed takes 0.1–0.6 s on either. The front end (parse, check, transform)
is 21–38 s in every cell, so a warm build is bound by it: the bundle cuts a cold build by 27%
(debug) and 15% (danger) and saves 2–3 s of compile and link on a warm one. Seconds are this
desktop's; only the ratios carry to the gate hosts. Store hits were not counted.

The edit loop of the compiler itself, measured the next day on oci-u (load 85–110 on 96 cores, so
a direction, not a figure), candidate on managed zig, `MSC_FLOWS`: a one-line edit to
`src/utils/string.ms`, `src/compiler/usage.ms` or `src/checker/types.ms` rebuilt in 64–73 s, of
which `phase.A` was 44–52 s with every one of 449 modules transformed and analyzed again,
`phase.graph` 13–16 s, and compile plus link about 3 s. The lever left for that loop is reusing
each module's front-end output across builds, not the C compiler.

## Measured 2026-10-27 — the check stops cloning the parse tree

Mac `sample` of `check src/index.ms` on `e5c088569`: the per-file parse tree clone was 15.4%
(a third of it the cycle collector triggered by its allocations), the collector 13.3% overall
(owned by the collector work, not here), `checkViewBorrows` 3.6% (four pre-walks per body).
Three fixes, landed as `58b52d63b`: a db that is not kept (`msc check`) checks the parse tree
itself; a clone no longer registers each fresh node as a cycle root; `checkUnit` walks a body
once. Emitted C of `src/index.ms` is identical (0 of 824 files differ).

lc-1, both two-stage builds with `--mm=drc --danger --lto=off --cc=clang`, interleaved, wall:

| cell | rounds | main `e5c088569` | cand |
|---|---|---|---|
| `check src/index.ms` | 7 / 7 | 19.04 s [17.14–19.63] | 15.58 s [14.96–17.10] |
| emit-only | 5 / 5 | 66.38 s | 65.05 s (ranges overlap) |

- `check` is 18% faster; emit-only does not move beyond noise.
- Also skipping the clone inside `msc build` took `phase.graph` from 16.6 to 14.9 s under
  `MSC_FLOWS`, but the collector's work moved into later passes (`b.raises`, `lowerLambda`,
  `lowerActorHandles`) and emit-only stayed at 62.68 → 62.70 s (5 rounds), so it was not kept.
  A faster build needs the collector's own cost to fall first.
- Not verified: Windows; the LSP path (a kept db still clones).

## Measured 2026-10-22 — four more front-end fixes

Same methods as 2026-10-21 below. All four leave emitted C of `src/index.ms` identical
(0 of 376 files differ).

| fix | workload (Mac, thin LTO) | rounds | instructions | user |
|---|---|---|---|---|
| 4 `std/fs/path.ms` `normalize` returns a path already in normal form; `relative` slices a descendant | emit-only | 3 | 335.1G → 318.9G (−4.8%) | noise |
| 5 `ast/visitor.ms` `forEachChild` without a closure per call | emit-only, on top of 4 | 3 | 319.4G → 311.0G (−2.6%) | 31.84 → 30.15 s |
| 6 `module/loader.ms` header-import scan by byte | `check src/index.ms`, on top of 5 | 5 | 62.96G → 62.00G (−1.5%) | 4.79 → 4.52 s |
| 7 `transform/walker.ms` one closure per walk, not per node | emit-only, on top of 6 | 3 | 313.1G → 303.4G (−3.1%) | 37.82 → 36.68 s (load 45–115) |

lc-1 (load 0.1–7), `main` = `301653fce`, `cand` = `main` + fixes 4–6, both built by one builder
with `--gc=drc --danger`; same cells as the baseline, min user CPU, wall in brackets:

| cell | rounds | main | cand |
|---|---|---|---|
| check | 5 / 5 | 13.00 s (13.9) | 13.05 s (14.0) |
| emit-only | 5 / 5 | 59.70 s (54.4) | 57.30 s (53.2) |
| rebuild 1 file | 3 / 3 | 59.70 s (54.4) | 57.72 s (52.4) |
| cold | 2 / 2 | 595.2 s (2:31) | 591.2 s (2:29) |

- Fixes 4–6 take 4.0% off emit-only and 3.3% off a one-file rebuild on lc-1; `check` does not
  move there, so fix 6's Mac gain is below that host's noise.
- Not verified: fix 7 on lc-1; Windows.

## Measured 2026-10-21 — self-host baseline, and three front-end fixes

**Baseline, Linux x64 (lc-1, 8 cores, load 1.1–5.5).** Two stage-2 compilers, each built by
its own stage 1 with `--gc=drc --danger --lto=off`: `main` = `d64faf905`, `cand` = `main` + the
string-match label count (fix 1 below). Every command ran from a clone of `main` with
`MSC_NO_GLOBAL_CACHE=1` and a private `out/`; rounds interleave the two binaries; the table
gives min user CPU (`/usr/bin/time -v`), wall in brackets. `perf` is not permitted on that
host, so there are no instruction counts.

| cell | command | rounds | main | cand |
|---|---|---|---|---|
| check | `msc check src/index.ms` | 7 / 5 | 14.34 s (15.4) | 14.20 s (15.2) |
| no-change | `build src/index.ms --gc=drc --danger --lto=off --output=… --time`, record settled | 5 / 5 | 14.80 s (16.1) | 14.83 s (16.1) |
| rebuild 1 file | same, after appending a comment to `src/utils/string.ms` | 5 / 5 | 57.73 s (52.7) | 62.40 s (57.3) |
| cold | same, `out/` moved aside | 3 / 3 | 604.3 s (2:35) | 602.5 s (2:34) |
| test | `msc test src/index.ms` | 1 / 1 | 631.1 s (6:12) | 630.1 s (6:09) |

- A no-change build costs one `check`: it stops at "Up to date" after graph load and check.
- Rebuilding one file reruns the whole front end: phase A 31 s wall (`graph load+check` 15 s),
  DCE 7 s; of a cold build's 2:35, phase C (codegen + clang) is 99 s.
- Within one binary, rebuild-1-file rounds spread 57.7–69.0 s, so main vs cand there is noise.
  Fix 1 shows no gain on this host in any cell; on the Mac it does (below).
- `test` is red on both binaries in the same 11 cases (`preludePack`, the prelude seed tests of
  `compile.ms`): they need the global cache that `MSC_NO_GLOBAL_CACHE=1` turns off.
- A build started within the same second as the last source edit drops the project record
  (`writeProjectCache`, the `modifiedTime(path) >= _buildStartedSeconds` guard), so the
  next build reruns the whole front end: 57–69 s here instead of 15 s. A first battery that
  rebuilt right after `git checkout` measured that, not a no-change build.

**Fixes, macOS arm64 (load 8–44; min of interleaved rounds, `time -l` instructions retired as
the load-independent number).** Binaries built by one builder with the same flags, A = before,
B = after; emitted C of `src/index.ms` compared file by file.

| fix | workload | rounds | instructions | user |
|---|---|---|---|---|
| 1 `matchLower.ms` counts string labels, not arms | emit-only, stage 2, `--lto=off` | 3 | 468.0G → 368.4G (−21%) | 45.37 → 30.80 s |
| 1 | emit-only, stage 2, thin LTO (shipping config) | 3 | 349.2G → 342.4G (−1.9%) | 29.70 → 26.14 s |
| 2 `loader.ms` line starts in one `split` | `check src/index.ms`, thin | 5 | 74.83G → 70.16G (−6.2%) | 4.77 → 4.52 s |
| 3 `scanner.ms` identifier sliced once | `check src/index.ms`, thin, on top of 2 | 5 | 70.25G → 64.20G (−8.6%) | 4.37 → 4.13 s |

- Fix 1 changes emitted C on purpose (15 of 375 modules gain `switch` on `msStringHash`); it
  reaches the compiler binary only at stage 2, so a published binary carries it one sync later.
  Thin LTO inlines `msStringEquals`, which hides most of the chain it removes.
- Fixes 2 and 3 leave emitted C identical (0 of 375 files differ). Fix 2: on a non-ASCII source
  `indexOf(s, from)` re-walks UTF-8 from the start, so the old newline loop was quadratic;
  `inlineHeader` time over 404 modules fell 422 → 86 ms.
- LTO axis, same source: thin vs off is −7.5% instructions on `check` (81.1G → 75.0G) and
  −7.2% on emit-only (368.6G → 341.9G); user 5.75 → 5.34 s and 32.54 → 28.78 s at load
  19–45. This contradicts the 2026-09-27 "within noise" below, which compared user time only.
  Default cc vs clang at `--lto=off`: 81.9G vs 81.2G.

Tried and dropped (no time gain): `memchr` in the non-ASCII `msStringIndexOf` path (−0.7%
`check` instructions); caching disk reads per source provider plus one module identity per
import edge (75.14G vs 75.27G). Not verified: Windows; fixes 2 and 3 on lc-1 (written after
its battery started); `test` and cold builds with fixes 2 and 3.

## Measured 2026-10-08 — build-object reuse, test gap and missing-header false hit

Snapshot `1090f7899`, tree `5d2c1980d324f06890ea612e51ab3addc502fda0`.
The consumer was installed v0.3.2, binary/support BUILD `2d7abb082`,
SHA-256 `7325946d4fae8732eb77af957377cce1913958f402014a24e0e88ccc3271a73c`.
Its `src`, `std`, `runtime` and `vendor` trees match the snapshot; only
`tools/gate.sh` differs between those commits.

Shared macOS arm64 host, Apple clang 21.0.0, private fresh HOME and local
caches, roots with and without spaces, and one counted driver limited to two
actual C compiler processes. No real user cache was wiped.
Commands used `build main.ms --output=app` or `test main.ms`, with
`--cc=<counted-clang> --lto=off --emit-jobs=1 --colors=off --verbose -t`.
A fresh local state used a new empty `MSC_CACHE_DIR`, not a shared mutable
project cache. Counts below are actual compilation/link invocations.

| Consumer and cache state | Native / generated / dispatcher compilations | Links | Result |
|---|---:|---:|---|
| Simple app, A cold | 23 / 1 / 1 | 1 | `42` |
| Simple app, B fresh with A's shared objects | 0 / 1 / 1 | 1 | `42` |
| Simple app, A local-warm | 0 / 0 / 0 | 0 | `42` |
| Simple app, A new local cache | 0 / 0 / 1 | 1 | `42` |
| Shared-module app, A / B fresh roots | 0 / 2 / 1 → 0 / 1 / 1 | 1 each | `42` each |
| Shared-module app, B new local cache | 0 / 0 / 1 | 1 | `42` |
| Tests, B fresh or A new local cache | 0 / 49 / 1 | 1 each | 299/299 each |
| Tests, A local-warm | 0 / 0 / 1 | 1 | 299/299 |

The simple app was `console.log(42);`. Both shared-module app roots imported
the same `../shared/lib.ms`, exporting `twice(value: int32): int32` as
`value * 2`; B restored that module and compiled only its own entry.
The two test roots instead contained byte-identical copies of that library
and tests asserting `twice(21) == 42` and `twice(-3) == -6`.
Both roots compiled 49 generated C files, **47 byte-identical**, while B
restored all 97 native objects. Four test runs passed 299/299 each.
Inspect `src/compiler/compile.ms` `cmdTest` for the generated-object path;
shared build restoration is in `src/compiler/cache.ms` `restoreModuleObject`.

Separate ordinary edits preserved invalidation: a native header changed
stdout `11` to `22`, the shared library changed `42` to `63`, and an entry
edit changed `42` to `43`. These do not establish every invalidation axis.

The missing-header consumer declared `probeValue` in `api.h`; its entry used
`@include("./api.h")`, `@compile("./native.c")`, an extern declaration and
`console.log(probeValue())`. The native source was:

```c
#if __has_include("optional.h")
#include "optional.h"
#else
#define VALUE 11
#endif
int probeValue(void) { return VALUE; }
```

Initially no `optional.h` existed; stdout was `11`. After creating it with
`#define VALUE 22`, a new-local/shared-cache build restored the old native
object, compiled no native source, exited 0 and still printed **`11`**.
With the same compiler, cwd, source and headers, `MSC_NO_GLOBAL_CACHE=1`
and another empty local cache compiled native source and printed **`22`**.
The control also changed the counter-log filename; no program input changed.
The originally absent header is not in the first native dependency record.
Inspect `src/compiler/cache.ms` `storeManifest` and `presenceSignature`. No fix was applied.

Raw commands, sources, counters and output are retained in the machine-local
`~/metascript/.wt/evidence/2026-10-08-cache-reuse-main-audit.json`.
The private fixtures, driver and caches were removed after capture.
Not verified: JS or other hosts, concurrency/collection, retention, other
target/GC/optimization/toolchain variants, a full gate or any prospective
speedup A/B. The old local-only build-object observation below is historical,
not the current shared-store baseline.

## Measured 2026-10-05 — output identity inside the filesystem settle window (Windows x64)

The link-cache rewrite invariant failed during integration on `e8bf07ba`; its
cache implementation was unchanged from base `5c4246fb`. The correction from
`3d58ade7` reuses the existing settle rule; implementation and deterministic
consumer tests live in `src/compiler/cache.ms`.

On the integrated tree `ea6b6ab8`, a native consumer repeated 200 times:
write `first`, record the link cache, check the fresh hit, write same-size
`other`, then check for a stale hit. Output: `fresh link hits 200/200; wrong
rewrite hits 0/200`. The compiler was the integration gate's `--danger`
candidate, compiling the current cache source; this was not an isolated speed
benchmark. The cache module and its dependencies passed 761/761.

The cache owner reported the same rewrite probe on base code yielding 71/200
and 72/200 wrong hits, then 0/200 twice with the correction; those counts were
printed in that session, not independently re-run here. The owner also
mutation-checked both new settle-window tests by removing the settle check.

A successful link-cache hit promotes its verified content record once the
output has settled. Project-level up-to-date checks remain content-based until
a later real build rewrites their record; no stamp-only project-mode warm-hit
speedup is claimed. Full-suite, HCR, corpus and SAN verification belongs to
the combined integration gate, not these focused measurements.

## Measured 2026-10-04 — prelude serialization and compiler coexistence (Windows x64)

Control source tree `ed9d96bc8e9dcaddf87835a75cb8e4ead953aa74` (`7d2fc199`).
Control and candidate used the same std/runtime root; probe binaries were built with
`--danger --lto=off`. The machine was shared, not an isolated performance host.

A native probe obtained the real prelude with
`checkPreludeFromSource(resolveRuntimeDir() + "/std", ".cms")`, then timed three
`writePreludePack` calls per process. Three interleaved control/candidate pairs
gave nine writes each: median **925.514 → 282.590 ms**, ranges 848.645–957.300
and 253.082–403.473 ms. All resulting **2,492,423-byte packs were identical**.
The implementation and storage guards live in `src/checker/preludePack.ms`.

Two compilers sharing a std root previously gave deps-seed hits **0,1,0,0**
for A,A,B,A; after compiler-key isolation a candidate and its byte-appended twin
gave **0,1,0,1,1** for A,A,B,A,B. Generated C stayed identical on cold and warm
paths. Compiler coexistence and format ownership guards failed before their
respective fixes and passed afterward.

Graph-check changes (`src/checker/orchestrator.ms`, `checkModuleGraph`) preserved
all 134 C outputs for corpus 013/515/817/821 × DRC/ORC, four JS bundles, and all
351 C outputs when emitting the control compiler itself. Those eight native
app runs and four JS runs preserved stdout/exit; retained warm/generic HCR builds
also passed. A single self-host emission pair took 32.717 → 30.625 s wall,
with a warm control seed and cold candidate seed: not an isolated speed estimate.

Rejected: concatenating unchanged runs in `mangleModuleName` instead of individual
characters, 75.266 vs 75.502 ms for 20,000 calls; no measured gain, reverted.
Not measured here: an after-change full-gate speedup, peak RSS, or other hosts.

Gate measurements on the shared Windows host are not an A/B speed comparison:
- `tools/gate.sh --release` at `e68761b9`, tree `403f10323ef8ec76489cb5c355e7fb8809b6cf2e`:
  GREEN, 0 new, **30m04s execution + 37m47s FIFO wait = 67m51s wall**. Lanes ran
  in phases; summing concurrent lane durations does not give wall time.
- The optimization land at `a98052a2`, tree `76f773b373ef73c7778d281ff1c5b51473f5ec85`:
  GREEN build/suite/tests/selected corpus, **18m27s**, of which **13m52s** was
  selection over 542 programs. Control/candidate signature files were byte-identical.
  The selector's three C "differences" were known emit failures on both sides
  (704-macroExprHoist, 762-bitSetMacro, bitSetVectorLifecycle), not changed C hashes;
  failure-inclusive selection deliberately kept them for execution. All 539
  successful C comparisons matched; JS signatures also matched.
## Measured 2026-10-05 — independent output/configuration records

The accepted slice is project build-record isolation, not a new native cache. Source
tree `151cbd4023474de8cd5f1cdf4e50db530696185f`, binary SHA-256
`523ad0cf317fde8a0f07a501050b2fe018698e98df4a349e18e2ed5dd0627408`;
source-matched control `e5e932d0`, binary SHA-256
`1aa962d7c04806883316bf9d65875ae5ea7e8839ba44ddeb691e7771858b67fc`.

Shared Apple Silicon host, isolated HOME/local directories per compiler, global objects
disabled (`MSC_NO_GLOBAL_CACHE=1`), and the same counted clang wrapper limited to two
actual compiler processes. The app was `console.log(179);`, in a root containing spaces.
Command: `<compiler> build main.ms --cc=<counted-clang> --lto=off --emit-jobs=1
--colors=off --verbose --output=<A>`; B used `--release --output=<B>` in the same local
cache. Prime A, build B, then measure returning to A; alternate compiler order between
three pairs and return to B between pairs.

| Return to A after B | Control | Candidate |
|---|---:|---:|
| Wall seconds, three runs | 2.007 / 2.095 / 2.089 | 1.084 / 1.099 / 1.206 |
| Median seconds | **2.089** | **1.099** |
| Dispatcher compilations / links, each return | 1 / 1 | **0 / 0** |
| Preprocessor calls | 0 | 0 |
| App stdout | `179` | `179` |

This workload's median improved by about 47%; all three paired returns were faster.
The deterministic gain is avoiding dispatcher preparation and linking after another
output/configuration used the cache. Graph loading and checking still run. This is not
a cold-build, cross-worktree object-reuse or general throughput claim.

Consumer pin: `src/test/nativeBuildBoundary.ms`, group `project-cache`. Two independent
roots (one with spaces) gave two old-control failures; the candidate passed
eight contracts, including debug/release values `157`/`163` and changed-native-source
invalidation to `167`. The final source check reported `OK no type errors in 367 module(s)`.
C and JS app consumers both printed `179`.

`src/compiler/cache.ms` passed 18 focused contracts. Its transitive test command was
not fully green: the same 11 color-length assertions failed on unchanged control source
and on the candidate (control 729 pass/11 fail; candidate 731 pass/11 fail). No color
implementation was changed. A separate publication probe changed from
`initial hit / stale success accepted` before the guard to
`initial hit / changed source rejected` after it.

The implementation is in `projectCacheChanged` / `writeProjectCache`; the external
reference's per-output record choice is `compiler/extccomp.nim`
`jsonBuildInstructionsFile` (1092–1096), with dependency/output validation in
`changeDetectedViaJsonBuildInstructions` (1151–1169). Native/global object protocols,
test-shard preparation and frontend persistence are unchanged. These measurements
precede the land gate; installed behavior is not claimed by this table.

## Rejected 2026-10-05 — bare native compiler input snapshots

A direct-clang input-snapshot experiment also failed the end-to-end performance bar:
three-run medians were control/candidate **0.712/1.184 s** unchanged and
**2.513/2.606 s** empty-local. Native scheduling changed 32 misses to 32 hits, but that
was not a speedup.

Materialized compiler cache results alone were also insufficient for safety: editing
external inline-assembly `.incbin` bytes should have changed output `97` to `98`,
but the bare snapshot candidate returned `97` again. A no-asm language flag was
rejected because it changes `__has_extension` behavior. Full AST reconstruction as
an eligibility guard cost **14.183 s** for a C++ cold consumer. The user reduced the
scope to independent build records; all native adapter/protocol source was removed.
Do not reintroduce any of these experiments based only on cache-hit counts.

## Measured 2026-10-03 — native restore succeeds, unconditional preprocessing regresses warm builds

Unlanded candidate tree `73b5d67d1fde4cc9acc0a3c88436bc99993c7002`, binary SHA-256
`75e4a4f5a370d57e34323e42babb24c48fb42fa29e8a2fa0b0fe344a902fddaa`; source-matched
control `e5e932d0`, SHA-256 `1aa962d7c04806883316bf9d65875ae5ea7e8839ba44ddeb691e7771858b67fc`.
Shared Apple Silicon host; isolated HOME/local caches and one counted clang driver limited
to two actual C compiler processes. Command: `<compiler> build main.ms --cc=<counted-clang>
--lto=off --emit-jobs=1 --colors=off --output=<app>`, with `HOME` and `MSC_CACHE_DIR`
set to the isolated roots. Counters distinguish `-E` preprocessing from `-c` compilation.

| Case | Control native/generated/dispatcher compiles; links; preprocesses | Candidate | App stdout |
|---|---|---|---|
| Cold root A | 32/15/1; 1; 0 | 32/15/1; 1; 79 | `42` |
| Local-warm root A | 0/0/0; 0; 0 | 0/0/0; 0; 32 | `42` |
| Empty local, warm global, root A | 32/15/1; 1; 0 | 0/15/1; 1; 47 | `42` |
| Distinct entry/root B, candidate cold then empty-local/global-warm | not re-run | 32/15/1; 1; 79 → 0/15/1; 1; 47 | `30` |

Interleaved unchanged builds with independent output paths: control **0.568 / 0.561 s**,
candidate **3.297 / 3.674 s**, zero compilation/linking on both. The candidate's 32
preprocessor calls remain on every warm project hit. These are shared-host observations,
not throughput forecasts. Successful object restoration alone is not a performance win.

The discarded experiment's `nativeBuildBoundary.ms` groups `cache-reuse` and
`cache-races` ran **9 pass**, including seven control failures and two unchanged
header-invalidation controls. Those experimental groups were removed with the
native prototype on 2026-10-05; only the independent project-record consumer remains.
The old failures covered two empty-local roots, include shadowing, optional headers,
independent records and publication races.
Both entry variants also printed identical C/JS output (`42`, `30`). Retained LSP
valid/identical/invalid/identical/repaired input produced diagnostic counts `0/0/1/1/0`
and changed hover `int32` to `string`; no query-hit or semantic-cutoff counter was exposed.

Decision: do not land this preprocessing-per-lookup candidate as the cache performance fix.
Dropping preprocessing without complete include-resolution knowledge is not safe:
[direct-mode caches document the missing-header limitation](https://ccache.dev/manual/latest.html#_the_direct_mode).
The native-input experiment was removed after the 2026-10-05 scope reduction.
Its successful probes do not establish a permanent native cache contract.

Not verified: inline cache suite, full gate, full runtime/vendor/target/GC invalidation
matrix, concurrent publication matrix or installed behavior. Generated objects are still
local-only, test dispatcher/link preparation remains unconditional, and normal select/corpus
CLI processes do not retain a frontend query database.

## Measured 2026-09-26/27 — the dev-loop link tax is thin-LTO (Apple Silicon, 14-core)

Battery: 22 runs, min-of-rounds, uptime recorded per run (logs in
`/tmp/perf-baseline/` on the measuring machine), installed binary `d9d5e4a2`,
tree `90c6fb51`, machine idle at start (load 4.8).

| Config | wall (min) | phase D link | note |
|---|---|---|---|
| rebuild 1 file (comment), thin | **23.91s** | **14.82s (62%)** | clang 0.06s — object cache hit |
| rebuild 1 file, `--lto=off` | **9.07s** | **0.20s** | same machine, interleaved A/B |
| cold `rm -rf out`, thin | 37.96s | 15.50s | clang 11.4s (bitcode compiles fast) |
| cold, `--lto=off` | 42.07s | 0.25s | clang 28.5s — codegen paid at clang, once |
| no-change build | 3.83s | — | invocation floor, see below |
| emission, default vs `--emit-jobs=1` | 0.23s vs 2.73s | — | 341 workers, overlap=true |

The 2026-07-28 note below ("LTO choice is not the win it looks like") holds
for COLD builds only. In the dev loop the .c is unchanged, every .o is a
cache hit — but a thin-LTO link re-runs whole-program codegen every time
(15s here, swinging 15→55s across identical runs), while an off link of the
same objects is 0.2s of layout. Dev loop therefore builds with
`--danger --lto=off` (see CLAUDE.md §Build Commands).

The binary does not pay the LTO gain back on this workload: `msc check
src/index.ms`, interleaved ×5 (2026-09-27, load 6.2 at start), min **4.57s
user (thin) vs 4.61s user (off)** — within noise; quiet rounds differ ±5%
with unstable sign under external load. NOT verified: compute-heavy
workloads (corpus compiles) may still favour thin-LTO — release binaries
keep it.

Also re-measured: module count **356** (was 251); the invocation floor
(no-change build / `check` ≈ 3.8–4.0s wall, 0.9GB RSS) is graph load +
prelude-pack deserialize (~1.2s) + check (~1.6s) — the incremental-compilation
arc's target, not the C toolchain's. The `toolchainStamp` fixed cost below is
GONE as of this measurement: main-tree `vendor/` is 51MB now (was 3.0GB);
hello-world from a dev-tree binary runs 3.83s vs 1.06s warm from the
installed one.

## Measured 2026-10-05 — LTO on SBF (`--os=solana`)

platform-tools v1.57 (clang and ld.lld 22.1.2), LiteSVM; stage-2 compiler of `wt/sbf-lto`
against its base `09692dc8b`. CU counts are deterministic; build times were not measured
(load 12–47 during the runs).

`--danger` (or an explicit `--lto=`) compiles every module to bitcode, always full `-flto`;
the link merges it with `ld.lld -shared --entry entrypoint --undefined=abort --plugin-opt=emit-llvm
--lto-O<2|3>` (an `-r` merge when this was measured; see the 2026-10-11 section below), compiles the
merged module with the SBF clang (its frame errors still fail the build), then links as before. A
direct LTO link is refused: ld.lld gives bitcode the SBF machine (`0x107`) while clang's
objects and platform-tools' `libcompiler_builtins` are `EM_BPF` ("is incompatible with").
A thin `-r` merge writes only its last module, so SBF merges full whatever the strategy. A
build without `--danger` is unchanged (escrow `.so` byte-identical to base).

CU per operation through `std/solana/arithmetic` (100 iterations per shape, operands from an
opaque instruction byte, (CU − loop baseline) / 100; every shape logs the same value):

| shape | base `--danger` | LTO | shape | base `--danger` | LTO |
|---|---|---|---|---|---|
| i32 `a / b` | 26.7 | 18.7 | i64 `a / b` | 18.8 | 15.0 |
| i32 `a % b` | 23.0 | 15.8 | i64 `a % b` | 18.0 | 12.1 |
| i32 `a / 4` | 23.1 | 0.6 | i64 `a / 4` | 14.1 | 2.5 |
| i32 `a / 100` | 23.1 | 2.1 | i64 `a / 100` | 14.1 | 0.6 |
| i32 `a % 8` | 20.5 | 0 | i64 `a % 8` | 13.6 | 3.5 |
| i32 `x /= b` | 33.0 | 20.7 | i64 `x /= b` | 23.6 | 15.0 |
| i32 `x %= 3` | 26.6 | 11.1 | i64 `x %= 3` | 19.1 | 1.5 |

Escrow (`examples/escrow`, `--danger`): `.so` 76,144 → 67,928 bytes; every LiteSVM scenario
passes; make 31,025 → 28,590 CU, take 24,686 → 21,132, make (refund) 38,525 → 36,090,
refund 18,787 → 16,590, refused 619 → 519.

Hibernal's `settleAttack`, unsplit (probe copy of Hibernal `0c4ad93`): frame 5,696 bytes on
base (over the 4,096 limit, the build fails) → 3,392 with LTO; with `wt/obj-constr-dest`'s
object-literal destination also applied, 4,032 without LTO → 3,200 with it. The probe runs
2,056 → 1,063 CU with the same logged value.

A release build with `--lto=thin` merges the same way (i32 `a / 4` and i64 `a / 100` 0.6 CU each).
Not verified: other platform-tools versions, Hibernal's full tree, std/solana's own deployed
programs.

## Measured 2026-10-11 — the SBF LTO merge internalizes

The merge was `ld.lld -r`, which keeps every hidden function external, so LLVM never internalized
one and the interprocedural passes saw each as callable from outside (the merged object of the
`nested` bench program listed 224 non-local functions). It is now a `-shared` link with
`--entry entrypoint`: lld internalizes every symbol the entry does not name, and the merged module
holds `entrypoint` and `abort` as its only non-local functions. `--undefined=abort` keeps the one
function the SBF backend calls to lower a trap after the merge; without it the final link stops
with `undefined symbol: abort`. The output stays `-emit-llvm` bitcode compiled by the SBF clang,
so the `.so` is `EM_BPF`, flags `0x3` as before (`llvm-readelf -h` on all five programs below).

`examples/anchorBench/<name>/program.ms --os=solana --release`, platform-tools v1.57, LiteSVM with
`tools/solana/mainnetInactiveFeatures.json`, base `f421de59b` → candidate; the 102 refusals of
`BENCH_REFUSALS=1` all still refuse with the state unchanged and every error string unchanged:

| program | `.so` bytes | compute units |
|---|---|---|
| helloworld | 4,048 → 3,064 | init 1,578 → 1,490 |
| vault | 3,784 → 3,504 | deposit 1,702 → 1,683, withdraw 490 → 482 |
| nested | 6,112 → 5,304 | initialize 2,913 → 2,827, increment 226 → 223, reset 218 → 215 |
| prop-amm | 5,504 → 4,208 | update 144 → 144, initialize 1,520 → 1,440, rotate_authority 167 → 168 |
| multisig | 15,392 → 12,296 | create 2,922 → 2,778, deposit 2,401 → 2,399, set_label 569 → 545, execute_transfer 2,919 → 2,865 |

`examples/escrow/program.ms --release`: 30,512 → 25,912 B, and `tools/solana/escrow.mjs` passes on
both. `rotate_authority` is the one operation that costs a unit more. Not verified: other
platform-tools versions, a Windows host.

## Measured 2026-10-11 — the raise check of an immediately called closure

`accounts<T>()` expands to a closure written and called in place. The raise inference could not
resolve its callee, so it counted every such call as one that can raise, and the entry, `dispatch`
and every handler above it carried `if (msErr) goto BeforeRet_`. It now follows the call to the
routine the closure was lifted to (a closure value written once, or a closure pair called in place
under manual memory), and the hooks that destroy a closure no longer count as an extern handed a
routine. A closure whose body raises, nested or not, keeps the check
(`src/test/c/raiseChecks.ms`). With the internalizing merge in both columns, the five programs
from the section above, before → after:

| program | `.so` bytes | compute units |
|---|---|---|
| helloworld | 3,064 → 2,960 | init 1,490 → 1,481 |
| vault | 3,504 → 3,504 | unchanged |
| nested | 5,304 → 5,224 | initialize 2,827 → 2,824, increment 223 → 220, reset 215 → 215 |
| prop-amm | 4,208 → 4,176 | update 144 → 144, initialize 1,440 → 1,438, rotate_authority 168 → 168 |
| multisig | 12,296 → 12,144 | create 2,778 → 2,776, deposit 2,399 → 2,397, set_label 545 → 544, execute_transfer 2,865 → 2,862 |

The same programs built `--lto=off` are byte-identical before and after the first half of the fix,
which is why the second half (the closure pair called in place, which `--gc=manual` produces and
`--gc=drc` does not) matters on this target. Not verified: a closure bound to a `let`, or copied
(`msClosureCopy`) or reassigned (`msClosureSink`), still counts as one that can raise.

## Measured 2026-10-11 — MsMain inlined

`MsMain` no longer carries `noinline` under `--os=solana` (it did since `d2835679f`). The LTO merge
folds it into `entrypoint`; a fold that overflows the 4,096-byte frame (a probe with a 2,800-byte
local reached from `main` made `entrypoint` 4,864 bytes: `Function entrypoint overflows the
maximum allowed frame space`) is caught where `linkSolana` fails, and the dispatcher is recompiled
with `-DMS_SOL_MAIN_NOINLINE` and relinked, with a `note:` on stderr. The same probe builds without
LTO unchanged. A program that needs the fallback pays one failed merge on every build.

Same five programs, before → after (the raise fix applied in both columns); the 102 refusals all
still refuse with the state unchanged and the error strings identical:

| program | `.so` bytes | compute units |
|---|---|---|
| helloworld | 2,960 → 2,912 | init 1,481 → 1,475 |
| vault | 3,504 → 3,432 | deposit 1,683 → 1,676, withdraw 482 → 475 |
| nested | 5,224 → 5,168 | initialize 2,824 → 2,817, increment 220 → 215, reset 215 → 210 |
| prop-amm | 4,176 → 4,128 | update 144 → 141, initialize 1,438 → 1,432, rotate_authority 168 → 165 |
| multisig | 12,144 → 12,000 | create 2,776 → 2,763, deposit 2,397 → 2,391, set_label 544 → 519, execute_transfer 2,862 → 2,858 |

No bench program needed the fallback (`solanaMainInlines.ms` builds one that does). Not verified: a
program whose fold overflows through code other than `MsMain` (the fallback does not help it and
the second link reports the overflow), other platform-tools versions.

## Re-measured 2026-07-28 (supersedes the tables below)

Apple Silicon 8-core, `msc build src/index.ms --gc=drc --danger --cc=clang`.
Historical measurement: **Phase A was 6.3s, not 24.7s** — it beat the plan's ~12–14s
target, but that does not establish that phases 3–10 shipped. The roadmap is obsolete;
the original measurement did not record its tree and was not rerun for this repair.

| Phase | Then (plan) | Now | Note |
|---|---|---|---|
| graph load + check | ~8s | **5.8s** | module graph load |
| A — parse + check + transform | 24.7s | **6.3s** | check 3.5s, xform 1.3s, analyze 0.8s |
| B — DCE | 0.7s | **0.4s** | |
| C — codegen + clang | 9.6s | **19.0s** | codegen 1.3s, **clang 13.7s** |
| D — link | 2.1s | **21.4s** | thin-LTO does whole-program codegen at link |
| total | 45–50s | **52.8s** | |

**The MetaScript half is now ~8s; the C toolchain is ~35s of the 53s.**
Optimising the compiler further buys little — the remaining lever is LTO
strategy. `--lto` is an axis separate from opt level (`off|thin|full`,
`cc.ms` `ltoFlags`); `--danger` defaults to thin. Measured cold, thin and
off finish within 0.2s of each other (55.6s vs 55.8s on a cold global
object cache) because the work just moves between compile and link — so
LTO choice is not the win it looks like. What actually moves the number
is cache state: the same cold-`out/` build costs **~32s** once
`~/.metascript/cache/objects/` is warm, and a rebuild after touching one
file lands **20–35s**.

Beware of comparing single runs: build wall time in this tree swings
20s→65s purely on cache state. Two measurements taken minutes apart
suggested a fresh binary was 2.3× slower than the installed one; a
controlled A/B (`rm -rf out` for both) showed **32.47s vs 32.25s** —
identical. Always re-measure both sides under the same cache state before
attributing a regression.

### Test suite — the real dev-loop cost, and where it went

`msc test src/index.ms` test-execution time: **419.6s → 17-19s (~23×)**,
3342/3342 unchanged. Wall clock for the whole command is ~40s, because
compiling the test binary (~21s warm) is now the larger half. The entry-by-entry
cost table that followed from this (full battery cheaper than a single-module
entry) was dropped on 2026-09-19: `msc test src/test/fixedbugs/bug048.ms` took
12 s wall at load 18 that day, and the full suite was not timed beside it, so the
comparison is open. The scope regression now lives in [`src/test/lang/testBlockScope.ms`](../src/test/lang/testBlockScope.ms); the timing above remains historical. Cache and load traps: [`TESTING.md`](TESTING.md).

Root cause was not codegen or clang: `checkProgram()` — the convenience
wrapper every inline test uses — called `buildPreludeContext()` on
**every** invocation, re-parsing and re-checking the whole std prelude
(~1s each). `checkPass.ms` alone has 213 such tests → 219.7s, 52% of the
suite. The three other prelude call sites (`eval.ms` `_raiserPreludeCtx`,
transam `db.preludeCtx`, orchestrator's per-compile `baseCtx`) already
cached; `checkProgram` was the lone outlier. Fixed by a
`standalonePreludeCtx()` accessor matching the `raiserPreludeCtx()` idiom.

Do NOT push that cache down into `buildPreludeContext` itself: the
orchestrator stamps `targetOs` onto its base context, so a shared
instance would leak one build's target into the next.

Note this does **not** speed up `msc build` — the build path checks
through `checkProgramWithRegistry`, which never touches the wrapper
(controlled A/B above confirms: 32.47s vs 32.25s).

Suite time after the fix is dominated by `lsp/handlers/lifecycle.ms`
(35s ≈ 65% of what remains), then `orchestrator.ms` 9s and
`transam/index.ms` 5.4s. The harness itself is in the C runtime
(`runtime/core/test.h`) and runs one linked binary serially (~150% CPU) —
parallelising it is the next lever if the suite needs to get faster still.

---

## Context & Current State

Self-build timings on a typical dev laptop (Apple Silicon, 8-core, warm OS cache) as of this plan:

| Workload | Time |
|---|---|
| User `msc run hello.ms` — first run on machine (cold) | **2.4s** |
| User `msc run hello.ms` — global cache hit | **1.0s** |
| User build, fresh project (global cache hit) | **2.1s** |
| Compiler self-build — native `msc build src/index.ms --gc=drc` cold | **45–50s** |
| Compiler self-build — native incremental (no source change) | **8.7s** |

### Already shipped (don't re-plan)

- **Phase 1 — Global `.o` cache** at `~/.metascript/cache/objects/` (content-addressed, VERSION-stamped, safe across upgrades). Hits for all `@compile` runtime/vendor `.c` files.
- **Phase 2 — Parallel `@compile` directives** via `spawn`/`waitFor` (`processCompileDirectives` gather → dispatch → collect). Real thread-level parallelism on the C backend.
- **Lambda-lifting loop-escape fix** — closures created inside a loop body now allocate a per-closure env with a snapshot of captures. Unblocks spawn/.then/actor/stored-callback-in-loop correctness. Prerequisite for any further parallelization.

### Where the remaining time goes (native cold, per `--time` breakdown)

| Phase | Time | % | Dominant cost |
|---|---|---|---|
| A — parse + check + transform (251 modules) | **24.7s** | 55% | **DRC refcount overhead on AST infrastructure** |
| B — DCE | 0.7s | 2% | — |
| C — codegen + clang | 9.6s (codegen 4.6s, clang **only 2.5s**) | 21% | codegen walks |
| D — link | 2.1s | 5% | single clang invocation |
| startup / misc | ~8s | 17% | module graph load, project cache check |

Validated via `--gc=none` A/B: rebuilt msc without DRC, re-ran self-build.
Phase A dropped **24.7s → 14.6s** — confirms **~10s of Phase A is pure RC refcount ops**.

**We cannot ship `msc` with `--mm=none`** because `msc lsp` is long-running and would leak. The target is to reclaim that ~10s via smarter data structures and eliminated allocations, not by turning off DRC.

---

## Goal — MET, by other means. Re-justify before working the phases below.

| | Plan's target | Actual 2026-07-28 |
|---|---|---|
| Native cold self-build | ~15s | **32s** (`rm -rf out`, warm object cache); ~20s warm |
| Native Phase A | ~12–14s | **6.3s** — beat the target by 2× |

The earlier goal record found phases 3–5 had not shipped while Phase A had improved anyway.
Its source counts/tree were not recorded as a current audit; they are not today's status
verdict. The estimates below were attributed to that abandoned baseline, so they cannot
justify implementation work or predict current savings.

Do NOT pick up a phase because this file lists it. Re-measure Phase A first
(`msc build src/index.ms --time`); at 6.3s out of a 53s build it is no
longer where the time is. The remaining cost is the C toolchain — clang
13.7s + link 21.4s under thin-LTO — which none of these phases touch.

---

## Historical phase estimates — not implementation instructions

The estimates and execution order below describe an abandoned baseline, not current source,
measured savings available today or approval to start these changes. The earlier goal record
explains why the plan was dropped; current costs require a new flow-specific measurement.

### Phase 3 — Eliminate synthetic Token allocation in transforms

**Problem**: every `makeIdent`, `makeBlock`, `makeNumber`, `makeNull`, `makeBool`, `makeString`, and similar transform helper calls `createNode(kind, data, syntheticToken(loc))`. `syntheticToken(loc)` allocates a throwaway `Token` (heap + msRefHeader) used only to pass `.line` / `.column` into `createNode`, then immediately discarded.

`createNodeAt(kind, data, loc: SourceLocation)` already exists with 80+ per-kind overloads in `std/meta/node.ms:552+` — takes SourceLocation directly, no Token round-trip.

**Scope**:
- Replace every `createNode(K, D, syntheticToken(loc))` with `createNodeAt(K, D, loc)`
- Audit hot call sites in `src/transform/util.ms` + the lowering passes
- Delete `syntheticToken` once unused

**Files to touch**: `src/transform/util.ms`, `src/transform/lowering/*.ms`, `src/transform/native/*.ms` (grep for `syntheticToken`)

**Expected win**: **~2–3s** off Phase A.

**Risk**: low. Mechanical grep-replace. `createNodeAt` is the documented transform-builder path.

**Verification**:
- `msc check src/index.ms` — type-check green
- Cold native self-build with `--time` — phase A delta vs baseline
- Test suite — 2768 pass unchanged

---

## Phase 4 — `Node.comments = null` instead of empty-array-per-node

**Problem**: `createNode` / `createNodeAt` unconditionally set `n.comments = []`, allocating a fresh `msRefArray` (heap + RC header) per Node. Grep confirms `.comments` is read ONLY by `src/compiler/fmt/printer/*` during `msc fmt`. On `msc build` / `msc run`, `.comments` is 100% dead weight but pays the allocation cost for ~100K nodes per build.

**Scope**:
- `createNode` / `createNodeAt` in `std/meta/node.ms`: init `n.comments = null as unknown as Token[]`
- Parser `src/parser/util.ms:18` — lazy-init on first push:
  `if (node.comments === null) { node.comments = []; } node.comments.push(...)`
- Fmt readers — treat null as empty:
  `if (node.comments !== null && node.comments.length > 0) { ... }` (grep `.comments.` in `src/compiler/fmt/`)

**Files to touch**: `std/meta/node.ms`, `src/parser/util.ms`, `src/compiler/fmt/printer/*.ms` (small — ~6 call sites)

**Expected win**: **~1–2s** off Phase A. Proportional to Node count (~100K empty-array allocs eliminated).

**Risk**: low. Readers are few and localized to fmt.

**Verification**:
- `msc fmt some_commented.ms` — comments still preserved (manual spot check)
- Test suite green
- Native phase A delta

---

## Phase 5 — `SourceLocation` from `interface` to `struct`

**Problem**: `SourceLocation` in `std/meta/node.ms:213` is an `interface` (ref-counted, heap-allocated) despite being **16 bytes of plain int32** — `line`, `column`, `endLine`, `endColumn`. No reference fields inside. Every `Node.location = loc` under DRC does `msIncref(newLoc); msDecref(oldLoc)` — pure overhead.

Every Node has one. Every Token has line/column (not a SourceLocation directly, but the pattern compounds). ~100K+ SourceLocation instances per build.

**Scope**:
- Change `export interface SourceLocation` → `export struct SourceLocation` in `std/meta/node.ms:213`
- Audit consumers: anywhere that treats SourceLocation as nullable (`null as unknown as SourceLocation`) — struct can't be null; replace with a sentinel (e.g. `makeLoc(0, 0)`) or make callers handle it explicitly
- `Node.location: SourceLocation` — field becomes inline value instead of pointer; bumps Node struct size by ~8 bytes (vs pointer + deref)
- Verify no site that aliases the SourceLocation across lifetimes (e.g. stores a pointer somewhere and expects mutation visibility)

**Files to touch**: `std/meta/node.ms`, audit `src/**/*.ms` for `SourceLocation` null assignments and mutation patterns

**Expected win**: **~3–5s** off Phase A.

**Risk**: medium. Struct semantics differ — no null, copy-by-value. Any code that mutates a `loc` after assignment and expects the shared Node to see it would break. Needs a quick audit pass.

**Verification**:
- Type-check green
- Native phase A delta
- Test suite — unchanged
- Error location rendering correct (pick an example failing `msc run` and check that error messages still point to correct line/col)

---

## Phase 6 — Replace `NameSet` with `Set<string>`

**Problem**: `src/transform/context.ms:42` defines `NameSet` as `{ items: string[] }` with O(n) `nameSetContains` (linear scan) and O(n²) `nameSetAdd` (contains-check then push). Used in hot transforms: `lambdaLifting.ms` (13 call sites), `destructorLifting.ms` (46 call sites), `dce.ms` (12), `analyzer/inject.ms` (9), `codegen/c/declarations.ms` (7), etc.

Example load: lambda lifting's `rewriteOuterRef` calls `nameSetContains(capturedNames, d.name)` for every identifier in every statement. With 20 captured names × 10,000 identifiers per module × 251 modules = **50 million string comparisons**.

`Set<string>` already exists in `std/core/struct.ms:243` — hash-based open addressing, proper O(1) avg.

**Scope**:
- Option A (safer): update `nameSetContains` / `nameSetAdd` implementations to back `NameSet` with a hash set internally, keeping the external API intact
- Option B (cleaner): replace `NameSet` type with `Set<string>` at all call sites

**Files to touch**: `src/transform/context.ms` + call-site files

**Expected win**: **~2–4s** off Phase A (algorithmic).

**Risk**: low-medium. Semantic equivalence of Set vs NameSet operations; iteration order may differ (audit where `items[]` is iterated in order and whether order matters).

**Verification**: test suite, cold build timing.

---

## Phase 7 — `lookupVarType` / `lookupVarResolvedType` hashing

**Problem**: `src/transform/lowering/lambdaLifting.ms:176-190` — backwards linear scan over `varTypes: VarTypeEntry[]` on every lookup. Same algorithmic anti-pattern as `NameSet`. Called during env-field type resolution for every captured var.

**Scope**:
- Add `varTypesByName: Map<string, VarTypeEntry>` alongside the ordered array (preserves insertion-order semantics for other callers if needed)
- Rewrite `lookupVarType` / `lookupVarResolvedType` to use the map
- Keep `varTypes: VarTypeEntry[]` for anything that needs ordered iteration

**Files to touch**: `src/transform/lowering/lambdaLifting.ms`

**Expected win**: **~0.5–1s** off Phase A (algorithmic).

**Risk**: low.

**Verification**: lambda lifting tests pass; spawn-in-loop repro still correct.

---

## Phase 8 — Per-scope symbol hash map

**Problem**: `src/checker/symbol.ms:141` `lookupSymbol` does linear scan of each scope's `symbols: Symbol[]` up the parent chain. Uses `nameId: int32` (fast cmp) but iterates every symbol. Module scopes have hundreds of symbols; checker walks the chain per identifier.

**Scope**:
- Add `symbolsByName: Map<int32, Symbol>` to `Scope`
- `lookupSymbol` / `lookupLocal` use the map
- `symbols: Symbol[]` kept for ordered iteration where needed (e.g. codegen, export enumeration)

**Files to touch**: `src/checker/symbol.ms`

**Expected win**: **~1–2s** off Phase A (algorithmic, benefits both).

**Risk**: low-medium. Need to keep both representations in sync on add/remove.

**Verification**: test suite, native phase A delta.

---

## Phase 9 — `Symbol.{overloads,defaultParams,staticFields}` default to `null`

**Problem**: `std/meta/node.ms:101` — Symbol always has three `Symbol[]` / `Node[]` fields that are empty for 95%+ of symbols (non-overloaded functions have 0 overloads, most functions have 0 default params, non-classes have 0 static fields). Every symbol allocates 3 empty `msRefArray` structs regardless.

**Scope**:
- Change default to `null`
- Update `createSymbol` / wherever symbols are constructed
- Readers null-check before iterate

**Files to touch**: `std/meta/node.ms`, `src/checker/**/*.ms`, `src/transform/**/*.ms` (searchers: grep `.overloads`, `.defaultParams`, `.staticFields`)

**Expected win**: **~0.5–1s**.

**Risk**: low. ~10-20 reader sites to audit.

**Verification**: test suite.

---

## Phase 10 — `Token` from `interface` to `struct`

**Problem**: `src/lexer/token.ms:45` — Token is an interface. Contains `kind: TokenKind`, 2 strings (`value`, `rawValue`), 2 numbers (`line`, `column`). Strings under DRC are reference types, so the struct-with-refs pattern (struct containing string fields, compiler auto-generates destroy that decrefs strings) applies naturally.

~100K tokens per module lex × 251 modules = ~25M tokens total across a self-build. Each is currently a heap alloc + msRefHeader + inherent RC traffic.

**Scope**:
- `export struct Token` (requires auto-derived destructor since it owns 2 strings)
- Tokens become values in `tokens: Token[]` — array holds them by value
- Copy / move semantics audit for existing Token consumers

**Files to touch**: `src/lexer/token.ms` + `src/lexer/scanner.ms`, `src/parser/context.ms`, `src/parser/util.ms` (reads `.comments`), plus anywhere Token is passed around

**Expected win**: **~1–2s** on native.

**Risk**: medium. Token is used widely; copy-by-value semantics change.

**Verification**: test suite (parse tests), `msc fmt` sanity check.

---

## Phase 11 — `NodeData` inline in Node (big refactor, biggest potential)

**Problem**: Every Node has `data: NodeData`, which is always an object literal heap-allocated. `{name: "foo"}` for an Identifier, `{left, right, operator}` for a BinaryExpr, etc. ~100K allocations per build just for NodeData.

One path: fold Node + NodeData into a single flat struct using a discriminant and a "fat" union of fields — trading Node struct size for zero-per-node data allocation.

**Scope**: major. Affects every NodeData variant cast in the codebase (`node.data as BinaryExprData` patterns).

**Expected win**: **~2–4s** on native (largest single allocation-elimination win).

**Risk**: HIGH. This is a compiler-wide refactor.

**Suggested deferral**: after Phases 3–10 are measured. If the target still isn't met, pursue this. Otherwise, skip.

---

## Phase 12 — Parallelize module clang compilation (P3 from earlier discussion)

**Problem**: module compilation (`compile.ms:1017-1040`) serially invokes clang for each of 251 modules. Now measurable at only **~2.5s** cold because most modules hit the module-level cache (`isCCodeCached`). On a true-cold scenario (e.g. fresh CI checkout) this is ~50s serial → ~13s 4-way parallel.

**Scope**: same gather → dispatch → collect pattern as the Phase 2 `processCompileDirectives` refactor.

**Expected win**: **~1.5s** on warm cold-build, up to **~35s** on true-cold (CI / fresh checkout).

**Risk**: low. Pattern already proven by Phase 2.

**Priority**: lower than 3–10 — the clang work is already small in the common case.

---

## Phase 13 — DRC codegen optimizations (long-term)

Optimize the native codegen to emit fewer RC ops:

- **Escape analysis**: when an object doesn't escape its scope, skip incref/decref entirely (like Rust's borrow checker for the 80% case)
- **Move elision**: detect `let x = expr; use(x)` where `x` isn't used after — emit move semantics (zero-RC)
- **Coalesce dec/inc pairs**: consecutive incref-decref of same pointer in straight-line code cancels out
- **Inline hot RC paths**: `msIncref`/`msDecref` become macros for small objects, not function calls

**Expected win**: ~5–15s on the compiler self-build, but applies to **all user programs compiled with DRC**. Compound value across the ecosystem.

**Risk**: HIGH. Each optimization needs correctness proof (no use-after-free, no double-free).

**Priority**: after Phases 3–10. This is months of work; the infrastructure fixes above are hours each.

---

## Recommended execution order

1. **Phase 3** (syntheticToken → createNodeAt) — mechanical, ~2-3s, no risk
2. **Phase 4** (comments = null) — ~1-2s, localized
3. **Phase 5** (SourceLocation → struct) — **~3-5s, the single biggest DRC win**, moderate audit
4. **Phase 6** (NameSet → Set) — ~2-4s, algorithmic, benefits both backends
5. **Phase 7** (lookupVarType hash) — ~0.5-1s
6. **Phase 8** (lookupSymbol hash) — ~1-2s, benefits both
7. **Phase 9** (Symbol arrays null) — ~0.5-1s
8. **Phase 10** (Token → struct) — ~1-2s
9. Measure. If native cold ≤ ~16s, stop here — target met.
10. **Phase 11** (NodeData inline) — only if still gap remaining
11. **Phase 13** (DRC codegen) — independent long-term project

~~Phases 3–10 together: **~10–17s** savings on native Phase A. Phase A 24.7s → ~8–15s → native cold self-build ~15–25s.~~ **VOID** — Phase A reached 6.3s without any of them (see Goal). The projected savings exceed the phase's entire current cost; re-measure before believing any number in this section.

## Verification common to every phase

Each phase lands independently:

1. `msc check src/index.ms` — type-check green
2. `msc test src/index.ms` — test suite 2768 pass / 8 fail (baseline unchanged)
3. Cold native self-build with `--time`: measure Phase A delta

How to time anything on this shared machine:

- Report the **minimum** round per cell, never a sum or a mean. Run an untimed warmup first. A summed benchmark at load 4-54 once reported `direct` 0.74x of `tree`, and the min-of-rounds rerun of the same sweep gave 1.38-1.45x, with the opposite sign (2026-08-11).
- Interleave the cells within a round and reverse their order on alternate rounds. A fixed order measures the later cells warmer.
- Record `uptime` with the result. Ratios between interleaved cells survive load, absolute numbers do not, so say which one a conclusion rests on.
- If runs of one binary disagree on the sign of a difference, the measurement is broken. Fix it before averaging anything.
- `msc run` and a plain `msc build` compile at `-O0`. Time C output built with `--danger`.

## Non-goals

- Shipping `msc` compiled with `--mm=none` — breaks `msc lsp` (long-running, would leak)
- Rewriting the compiler in a different language
- External profilers / instrumentation harnesses — timing breakdown via `--time` is sufficient

---

## Historical measurement 2026-09-05 — support-tree stamp cost

**Symptom**: any `msc` binary sitting in the dev tree pays a ~45-60s FIXED cost per invocation (hello build: 44-64s real, user 23-27s, sys 10-16s), while the installed `~/.metascript/bin/msc` does the same build in 2.5s. Measured on two independent dev-tree binaries (one from a clean worktree, one from the main tree) in fresh target dirs; binary sizes are equal (~11.3MB), so it is NOT an optimization-level difference. `sample` puts the time in `collectFilesSorted` (`src/compiler/cache.ms`) plus memmove/malloc churn.

**Historical cause at that measurement** (tree not recorded): the support-tree stamp content-hashed the runtime/vendor trees per process. This is not the current algorithm: `toolchainStamp`, `compilerStamp`, `objectStamp` and `treesStamp` in `src/compiler/cache.ms` own it; `treesStamp` memoizes file hashes by change stamp across processes. The old per-invocation 3 GB rehash explanation must not be carried forward without measurement. In that experiment the compiler-root was the binary location, so the dev-tree binary scanned dev `vendor/` = **3.0GB** (rust 1.2G, zig 654M, typescript-go 507M, prettier 221M, biome 187M — reference clones, not C libs), while the installed root's `vendor/` is 51MB (argon2, mbedtls, miniz, monocypher).

**Historical test-rig experiment, not a current recipe**: pruning a standalone worktree's
vendor COPY to the installed set changed that probe from 52s to **1.74s** (30x). This record
does not authorize pruning a shared checkout, vendored inputs or another job's support tree.

**Downstream costs previously misattributed**: guard battery "~1.5 min/guard", corpus lane at ~105s/program (9h projection vs the documented ~19 min), worktree suite 228s vs 120s. All were this stamp scan, not slow binaries.

**Historical proposal, not a current pending fix or implementation approval**: `toolchainStamp` should stamp only the trees that can invalidate compiled artifacts (runtime headers + the C-source vendor libs actually reachable by `@compile`), or read a manifest, instead of walking whatever happens to live under `vendor/`.
