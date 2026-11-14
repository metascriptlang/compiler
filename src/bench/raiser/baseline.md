# Raiser bench baseline

Each table is one `src/bench/run.sh raiser 3` run: the median of three runs per arm, each run itself the median of
three rounds of at least 250 ms. Every row but `fib(25)` and `sha256` runs a loop of 1000 iterations, so its us/op
reads as ns per iteration, loop included; `int add loop 1k` is the loop with one add.

- `raiser` is `msc run --target=raiser bench.ms` with a candidate built as it ships: `--danger`, thin LTO (`--cc=clang`
  on macOS, where the default compiler cannot link LTO).
- `c` is the same `bench.ms` on C `--release`.
- `luajit-joff`, `luajit-jon` and `lua54` run `bench.lua` under LuaJIT 2.1 `ea9eb7edb5e` (interpreter, then JIT) and
  Lua 5.4.7, built from source by `src/bench/buildLua.sh`. `bench.lua` times with `os.clock` (process CPU time), since
  Lua has no portable wall clock; `bench.ms` times with `performance.now`.

The command, from the worktree:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- bash -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger [--cc=clang] --output=msc-cand && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> src/bench/run.sh raiser 3'
```

The hosts are shared, so a table carries its load; compare a new run against the table of the same host only.

Where the arms do different work for the same row: LuaJIT numbers are doubles, so `int to float` converts nothing
there, and Lua 5.4 converts inside the add. Under `-jon`, `object alloc` is sunk by the JIT and allocates nothing.
`string concat` is a new interned (hashed) string per step in LuaJIT and in Lua 5.4 a new copied string, which is why
the Raiser leads that row. `sha256 64 KB host bridge` has no Lua twin; against `c` it measures the `uint8[]` crossing
into the host bridge, which copies the buffer.

A row reads a module-level variable only when its name says so. A first one-round run, where `field read/write`,
`array index` and `closure call` read module-level objects inside the loop, measured them at 220, 73 and 93 us/op on
rtx, against 7.5, 7.0 and 19 us/op with a local copy below. `module object read 1k` names that cost.

## rtx — AMD Ryzen 9 9950X, Linux x86_64

Commit `b8cd6f4631e2` (main), builder msc `1b493b622aca`, 2026-11-13, load 11.1 before, 4.9 after (32 threads). Host
flags `--linux --host rtx --cores 16`; candidate built `--danger --cc=clang --passC=-g --passL=-g` (thin LTO).

| row | unit | raiser | c | luajit-joff | luajit-jon | lua54 |
|---|---|---|---|---|---|---|
| int add loop 1k | us/op | 2.285 | 0.188 | 2.21 | 0.475 | 2.188 |
| float add loop 1k | us/op | 2.683 | 0.339 | 2.227 | 0.349 | 2.249 |
| int to float 1k | us/op | 3.215 | 0.474 | 2.206 | 0.48 | 2.248 |
| fib(25) recursion | us/op | 2516.141 | 199.788 | 1684.635 | 268.442 | 2317.336 |
| module variable read 1k | us/op | 4.137 | 0.002 | 2.237 | 0.35 | 2.637 |
| module object read 1k | us/op | 4.845 | 0.099 | 3.114 | 0.347 | 3.82 |
| field read/write 1k | us/op | 7.693 | 0.198 | 7.71 | 0.404 | 11.754 |
| ms call 1k | us/op | 3.208 | 0.177 | 5.309 | 0.496 | 8.914 |
| closure call 1k | us/op | 16.065 | 0.924 | 6.682 | 0.491 | 10.141 |
| Math.sqrt host call 1k | us/op | 9.533 | 4.136 | 8.797 | 4.128 | 9.36 |
| user C sqrt call 1k | us/op | 12.827 | 4.072 | 31.19 | 4.139 | - |
| array push 1k | us/op | 2.991 | 0.511 | 3.666 | 1.081 | 5.242 |
| array index 1k | us/op | 3.761 | 0.194 | 2.738 | 0.355 | 3.32 |
| string concat 1k | us/op | 11.543 | 0.967 | 133.474 | 90.357 | 32.499 |
| Map set 1k | us/op | 286.361 | 3.069 | 11.431 | 1.656 | 3.996 |
| Map get 1k | us/op | 230.816 | 2.168 | 13.399 | 1.726 | 6.404 |
| object alloc 1k | us/op | 51.658 | 3.679 | 29.227 | 0.486 | 53.198 |
| union string tag 1k | us/op | 52.974 | 1.049 | 13.016 | 2.261 | 18.481 |
| union number tag 1k | us/op | 44.51 | 0.906 | 12.702 | 2.528 | 17.131 |
| int tag record 1k | us/op | 43.161 | 1.064 | 12.089 | 2.962 | 16.535 |
| sha256 64 KB host bridge | MB/s | 2658.575 | 2692.286 | - | - | - |

Against the 2026-11-08 table (`25e95678cd3`): module variable read 7.87 → 4.14 (module TDZ guard), Math.sqrt 22.7 → 9.53
and user C sqrt 25.6 → 12.8 (in-place host call); other rows within 10%, except `int to float` 2.64 → 3.22, one
run, not rechecked. Six of 20 rows reach `-joff` as before (field read/write, ms call, user C sqrt, array push, string
concat, int add at 1.03x).

### Where each row's gap comes from

Instructions per iteration, on main `25e95678cd3` (the 2026-11-08 table): Raiser counted at run time (a per-opcode counter applied to a probe
build only, each row's program run with and without the row, divided by 1000), LuaJIT read from `luajit -bl
bench.lua`. One plain instruction costs about 1.1 ns on both sides, so a row at parity runs as many instructions as
LuaJIT and a row behind runs more of them or dearer ones.

| row | Raiser | LuaJIT | what the extra is |
|---|---|---|---|
| int add, field read/write | 2, 8 | 2, 8 | none: parity |
| float add, int to float | 3 | 2 | a loop-invariant constant reloaded; the int conversion LuaJIT does not need |
| module variable / object read | 6 / 7 | 3 / 4 | a TDZ guard (LoadGlobal, BTruthy, two Jump) inside the loop; gone since `5a5d1a68eaf` (a binding is guarded only when a routine entered before its declaration reads it): 7.97 → 4.00 and 8.95 → 4.83 us/op on rtx, one low-load round (load 11 → 8), LuaJIT -joff 2.27 / 3.01 |
| fib(25), per call | 4.5 | 7.5 | fewer instructions: CallDirect+Ret costs about 7.7 ns against about 2 |
| closure call | 7 | 8 | CallClosureTyped about 10 ns |
| Math.sqrt | 5 | 5 | CallHost about 18 ns; LuaJIT runs `math.sqrt` as a fast function |
| object alloc | 18 | 6 | constructor not inlined; Try/Finally around each iteration, a constructor being assumed to raise |
| union / tag rows | 25–29 | ~13 | the `for of` element was an owned copy (RcInc, MoveR, WasMoved, Try/Finally/RcDec per element); a cursor since `b275ad7da4f`, the loop 18 → 10 instructions per element, but the rows moved only 3–6% (int tag 47.3 → 44.5 us/op, rtx): what remains is the call to `area` and its body |
| Map get / set | 94 / 102 | 6 / 3 | the std Map runs as bytecode across 6–8 routines; LuaJIT runs one table instruction in C |

The ns costs of the call opcodes are differences between rows, not measured in isolation. Not measured: m1m.

## m1m — Apple M1 Pro, macOS arm64

Commit `b8cd6f4631e2` (main), builder msc `1b493b622aca`, 2026-11-13, load 15.3 before, 9.1 after (8 cores): loaded,
so `-joff` itself reads slower than on 11-04. Host flags `--mac --cores 8`, `--cc=clang` on the candidate build. Lua 5.4
did not build on the host.

| row | unit | raiser | c | luajit-joff | luajit-jon | lua54 |
|---|---|---|---|---|---|---|
| int add loop 1k | us/op | 4.067 | 0.321 | 6.074 | 0.338 | - |
| float add loop 1k | us/op | 4.947 | 0.814 | 6.312 | 0.897 | - |
| int to float 1k | us/op | 4.556 | 0.829 | 6.076 | 0.337 | - |
| fib(25) recursion | us/op | 3745.463 | 290.015 | 3105.165 | 495.117 | - |
| module variable read 1k | us/op | 4.693 | 0.003 | 6.449 | 0.337 | - |
| module object read 1k | us/op | 5.563 | 0.321 | 7.343 | 0.363 | - |
| field read/write 1k | us/op | 9.149 | 0.329 | 14.529 | 0.571 | - |
| ms call 1k | us/op | 4.828 | 0.33 | 10.232 | 0.496 | - |
| closure call 1k | us/op | 22.94 | 1.305 | 11.083 | 0.607 | - |
| Math.sqrt host call 1k | us/op | 12.975 | 4.961 | 11.295 | 5.053 | - |
| user C sqrt call 1k | us/op | 17.396 | 4.829 | 35.943 | 5.015 | - |
| array push 1k | us/op | 5.097 | 1.101 | 8.328 | 1.584 | - |
| array index 1k | us/op | 4.795 | 0.487 | 7.325 | 0.591 | - |
| string concat 1k | us/op | 16.194 | 2.325 | 208.11 | 46.106 | - |
| Map set 1k | us/op | 415.66 | 6.484 | 14.432 | 2.051 | - |
| Map get 1k | us/op | 359.968 | 3.864 | 29.356 | 2.407 | - |
| object alloc 1k | us/op | 76.169 | 7.952 | 45.738 | 0.359 | - |
| union string tag 1k | us/op | 72.661 | 3.138 | 30.585 | 4.736 | - |
| union number tag 1k | us/op | 62.647 | 2.679 | 30.82 | 4.885 | - |
| int tag record 1k | us/op | 60.396 | 1.513 | 27.149 | 5.028 | - |
| sha256 64 KB host bridge | MB/s | 2368.275 | 2364.225 | - | - | - |

Against 2026-11-04 (`1b4eafd7173`): Map set 817 → 416 and get 842 → 360, module object read 78.3 → 5.56, ms call
24.0 → 4.83, Math.sqrt 92.7 → 13.0, sha256 bridge 316 → 2368 MB/s. Furthest from `-joff`: Map set (29x), Map get
(12x), int tag record, union string tag and union number tag (2.0-2.4x), closure call (2.1x), object alloc (1.7x).

## App-shaped rows

`apps/` holds two real programs with the modules they import, copied from neon `1973f212` and haro `3dc0935`:
`rowsEl` drives Neon's reactive core on its mock host (a keyed list of 1000 rows: create, update every 10th label,
select, swap, remove, append, clear; 20 iterations), and `haro` drives Haro's workspace model (splits, focus, resize,
a layout after each step) plus `urlSpans` over 2000 terminal lines (40 iterations). Each prints its own timer and a
checksum; `MSC=<candidate> apps/run.sh 3` builds C `--danger`, runs both arms and refuses a checksum that differs.
The Raiser time excludes its front end, which is about 19% of a run's wall time on both programs.

Main `b8cd6f4631e2`, 2026-11-13, median of three runs:

| host | rowsEl c ms | rowsEl raiser ms | ratio | haro c ms | haro raiser ms | ratio |
|---|---|---|---|---|---|---|
| rtx, load 4-11 | 185 | 5893 | 32x | 96 | 5107 | 53x |
| m1m, load 15-21 | 279 | 7642 | 27x | 152 | 7770 | 51x |

Against the 2026-11-04 profile (`56ad1fdf80f`, rtx): rowsEl 32x → 32x, haro 88x → 53x. A run at load 23-26 on rtx
read 21x and 50x, its C arm slowed more than the Raiser: compare ratios at similar load only.

Where the Raiser's run time goes on rtx (LD_PRELOAD SIGPROF sampler, about 1 ms of CPU per sample, 6185 and 4927
run-time samples; categories by opcode arm and function):

| category | rowsEl | haro |
|---|---|---|
| alloc and counts (`allocBlock`, `findRegion`, `writeRef`, `rcDecIsLast`, RcDec, WasMoved) | 33.3% | 15.6% |
| fast dispatch (loop head, indirect jumps) | 12.4% | 17.3% |
| slow-path bridge and boxed register access (`writeAbs`, `setRegConform`, `getDyn`) | 9.5% | 15.8% |
| calls and returns (CallDirect, Ret, `leaveFrame`, safepoints) | 10.1% | 9.2% |
| moves, constants, conversions | 4.8% | 9.8% |
| field and global reads and writes | 7.0% | 4.7% |
| array ops | 6.1% | 5.9% |
| strings | 0.3% | 4.7% |
| cycle collector | 2.4% | 0.1% |

The slow-path bridge fell from 26-36% (11-04) since RcInc, RcDec and WasMoved run in the dispatch loop; allocation and
counts now lead rowsEl, and on haro the boxed register path is what remains of the bridge.

### Counted: what each app row executes against C

Per run of each program on rtx, 2026-11-13. Raiser counts come from a probe build of tree `d31a173a7b37` (an opcode
counter at the dispatch loop head and a counter in `allocBlock`, applied to a copy of the tree); C counts from
`--passC=-DMS_DRC_STAT` with `MS_DRC_STAT=<file>`. C's DRC counters cover ref cells, not string payloads, so the
allocation rows compare cells only on rowsEl, where strings are few.

| | rowsEl raiser | rowsEl c | haro raiser | haro c |
|---|---|---|---|---|
| instructions | 1.67G | - | 2.44G | - |
| RcInc + RcDec | 221M | 38M | 208M | 1.4M |
| VM block or cell allocations | 13.9M | 2.9M | 17.5M | 0.09M |
| Try + Finally + FinallyEnd | 44M | - | 207M | - |

Before `c644004eed43`, 7.7M of rowsEl's allocations were boxes holding the address of a `Ret` that left a Try/Finally
the analyzer puts around a local's cleanup; that commit and `a974c44d0850` (the finally run inline before the `Ret`)
took rowsEl to 6.3M allocations and haro to 15.7M, at the same instruction count. Wall time of the two together, a
quiet rtx window (load 2-3), five interleaved rounds of LTO candidates, control = tree `01d71ae1f5a9` with both diffs
reversed: rowsEl 5253 → 5066 ms (-3.6%), haro 5034 → 4898 ms (-2.7%), lower in every round. So halving the
allocations bought about 4%: the "alloc and counts" share of the profile above is mostly the count operations and the
boxed register path, not the allocator.

Left after both, by the same probe: rowsEl boxes Object values loaded into Dyn registers (`LoadSlot`, about 1M);
haro boxes Int fields read into Dyn registers (`LoadFieldRequired` in `changes`, 0.82M) and allocates strings and
arrays in `CallHost` (4.5M), `StrSlice` (3.7M), `NewArray` (2.4M) and `ConcatStrR` (2.3M).

haro's gap was one function: in `schemeAt`, `for (const scheme of SCHEMES)` reads each element borrowed on C and
owned on the Raiser, with a count, a `WasMoved` and a Try/Finally per element. The Raiser keeps `scheme.charCodeAt(0)`
as a member call for its opcode, and cursor inference marked the receiver of any member call written, where C sees
the same call as `charCodeAt(scheme, 0)` and judges `scheme` as an argument. Since `642e2092cf78` the receiver of an
extension called in member form is judged as that argument. Same probe, rtx, tree `642e2092cf78`, checksums equal
to C:

| | rowsEl raiser | haro raiser |
|---|---|---|
| instructions | 1.66G (1.67G) | 1.57G (2.44G) |
| RcInc + RcDec | 221M (221M) | 9.0M (208M) |
| Try + Finally + FinallyEnd | 44M (44M) | 8.4M (207M) |
| VM block or cell allocations | 6.3M (6.3M) | 15.7M (15.7M) |

`schemeAt` went from 54 instructions to 37. rowsEl does not take this path, so its counts stand. Wall time not yet
measured in a quiet window.

rowsEl's gap was `splice`, by a probe that keys RcInc, RcDec and Try by function: the generic `.rms` body shifted
every kept element with a counted copy, and `T[].splice` over `ref MockNode` carried 119M of rowsEl's 207M RcInc +
RcDec and 590M of its 1.59G instructions (both arms in danger mode). C rotates the payload with no count. Since
`7ea12454f96c` the generic `splice` and `reverse` run the `ArraySplice`, `ArraySplice3` and `ArrayReverse` opcodes,
which move the elements and release only those taken out (corpus `spliceReleasesOnlyRemovedElements`). Same probe,
rtx, both arms `--danger` (before: 1.59G instructions, 207M RcInc + RcDec): rowsEl 1.00G instructions, checksums
equal to C. `apps/run.sh` runs the Raiser arm in danger mode since `6aa07d7c365d`; until then it ran debug mode,
with Neon's `when (debug)` blocks and range checks, which cost rowsEl 4% of its instructions (1.66G against 1.59G).

### T0 bytecode slices, 2026-11-14

Four slices that change only the emitted bytecode, every program keeping its output: a for-of binding the analyzer
makes a cursor is bound by its element load with no `null` stored first (`2ef118fbb4e`, `tryHoistVar` in
`src/analyzer/inject.ms`); a loop reads each `const` module binding from a register loaded before it
(`07ec16cacc72`, `loadConstGlobalsBeforeLoop` in `src/codegen/raiser/statements.ms`); a branch into a test of a flag
its straight run just loaded with a constant lands where that constant leads (`a8ba553459f`, `threadConstantTests`,
which makes the `&&`/`||` flag of a fresh right operand cost nothing on the first operand's exit); a test of a Bool or
Word register is one `BrNeI64Imm`/`BrEqI64Imm r #0` (`b916f0053f3`, `jumpIfValue` in `expressions.ms`).

Same probe as above, rtx, both arms `--danger`, checksums equal to C, main `71bf722e2624` before and `b916f0053f3`
after:

| | before | after |
|---|---|---|
| haro instructions | 1.572G | 1.245G (-20.8%) |
| haro `schemeAt` | 1.048G | 0.725G |
| haro `LoadGlobal` | 139M | 11M |
| rowsEl instructions | 1.002G | 0.970G (-3.2%) |
| rowsEl `Jump` | 78M | 48M |
| rowsEl `BTruthy` | 38M | none |

Wall time, `apps/run.sh 3` medians in quiet rtx windows (`run-remote.sh --quiet 15`), C arm and Raiser arm both
`--danger`; the window before ran main `71bf722e2624` with the first slice applied, at load 8.8, and the one after
ran `b916f0053f3` at load 4.5:

| | rowsEl c ms | rowsEl raiser ms | ratio | haro c ms | haro raiser ms | ratio |
|---|---|---|---|---|---|---|
| before | 152 | 3798 | 25.0x | 82 | 3986 | 48.6x |
| after | 137 | 3342 | 24.4x | 81 | 3599 | 44.4x |

The C arm of rowsEl ran 10% faster in the second window, so compare the ratios: haro -8.6%, rowsEl -2.4%. What
rowsEl still executes most: `LoadSlotR` 111M, `MoveR` 68M, `LoadConst` 63M, `RcDec` 59M, `LoadInt` 56M, and a
Try/Finally around each scope's cleanup in its reactive core (`link`, `recompute`).

Two more on haro's `schemeAt`: a string read whose receiver and index a loop never writes is made once before
the loop (`2c7821f9306`, `loadInvariantReadsBeforeLoop`), and `charCodeAt` at a literal index is one
`StrCharCodeAtImm` (`44bfd693925`). Same probe on `44bfd693925`: haro 1.117G instructions (1.245G after the first
four, 1.572G at `71bf722e2624`, -28.9% in all), `schemeAt` 0.596G; rowsEl 0.970G, unchanged. Quiet rtx window at
load 2.3: rowsEl c 134 ms, raiser 3307 ms (24.7x); haro c 82 ms, raiser 3445 ms (42.0x, from 44.4x after the first
four and 48.6x before them). rowsEl takes neither path, so its 24.4x to 24.7x is the windows' spread. What haro's
`schemeAt` still runs per scheme: the `&&` flag's initial `LoadConstW` (113M in all of haro), dead once the branch
is threaded past its test, which a dead-store pass needs a per-opcode read/write table to remove.

A constant load into a Word, Bool or Float register that every path overwrites before reading it is dropped
(`4e72d876b67`, `dropDeadConstantLoads`): the `&&` flag's initial store once its test is branched past. Same probe:
haro 1.048G instructions (-6.1%; `LoadConstW` 113M to 46M; -33.3% from `71bf722e2624`), `schemeAt` 0.529G; rowsEl
0.969G. Quiet rtx window at load 3.8: rowsEl c 139 ms, raiser 3319 ms (23.9x); haro c 82 ms, raiser 3405 ms (41.5x
from 42.0x). The dropped loads are among the cheapest instructions, so wall time moves less than the count.

A for-of over a const bound to an array literal under a read-only array type checks no length after each element
(`forOfLower` `holdsFixedLength`, on every backend): no mutable alias of that array exists and a read-only view never
converts back, so the check could never fire. It was haro's `SCHEMES` loop in `schemeAt`, an `ArrayLen` and a branch
per scheme. Same probe on the slice's candidate: haro 0.916G instructions (-12.6%; -41.7% from `71bf722e2624`),
`schemeAt` 0.397G; rowsEl 0.969G, unchanged. Wall time not yet taken in a quiet window.

A try with no catch falls from its body into its finally instead of taking a `Jump 0` there, one dispatch per
cleanup scope run (`compileTryCatchStmt`). Same probe on the slice's candidate: rowsEl 0.962G instructions (from
0.969G), haro 0.914G (from 0.916G).

`===` and `!==` between two class instances held in Ref registers branch on their handles (`BeqR`/`BrNeR`, which
the register verifier already ranked from the integer forms) instead of the general value compare `EqVal`, which
ran on the VM's slow path (`compileCompareTest`, `holdsClassInstance`). Same probe on the slice's candidate: rowsEl
0.932G instructions (from 0.962G; `EqVal` 31M became `BrNeR` on the fast path), haro unchanged at 0.914G.
