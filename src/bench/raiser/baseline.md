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

Commit `25e95678cd3` (main), builder msc `02029f04dc4`, 2026-11-08, load 20.1 before, 7.1 after (32 threads). Host
flags `--linux --host rtx --cores 16`; candidate built `--danger` with the default thin LTO.

| row | unit | raiser | c | luajit-joff | luajit-jon | lua54 |
|---|---|---|---|---|---|---|
| int add loop 1k | us/op | 2.229 | 0.196 | 2.287 | 0.491 | 2.172 |
| float add loop 1k | us/op | 2.628 | 0.35 | 2.277 | 0.356 | 2.297 |
| int to float 1k | us/op | 2.643 | 0.477 | 2.281 | 0.492 | 2.302 |
| fib(25) recursion | us/op | 2543 | 205.7 | 1731 | 278.8 | 2426 |
| module variable read 1k | us/op | 7.872 | 0.194 | 2.289 | 0.355 | 2.549 |
| module object read 1k | us/op | 8.794 | 0.194 | 3.022 | 0.355 | 3.732 |
| field read/write 1k | us/op | 7.43 | 0.207 | 7.85 | 0.423 | 11.28 |
| ms call 1k | us/op | 3.136 | 0.185 | 5.287 | 0.505 | 8.68 |
| closure call 1k | us/op | 16.2 | 0.955 | 6.816 | 0.503 | 10.32 |
| Math.sqrt host call 1k | us/op | 22.74 | 4.26 | 9.027 | 4.184 | 9.187 |
| user C sqrt call 1k | us/op | 25.62 | 4.253 | 31.55 | 4.243 | - |
| array push 1k | us/op | 2.896 | 0.524 | 3.797 | 1.134 | 5.37 |
| array index 1k | us/op | 3.813 | 0.197 | 2.807 | 0.361 | 3.355 |
| string concat 1k | us/op | 13.04 | 1.022 | 133.1 | 89.76 | 37.86 |
| Map set 1k | us/op | 307.9 | 3.527 | 11.6 | 1.75 | 4.159 |
| Map get 1k | us/op | 243 | 2.429 | 13.6 | 1.764 | 6.554 |
| object alloc 1k | us/op | 56.86 | 2.725 | 29.76 | 0.498 | 52.58 |
| union string tag 1k | us/op | 55.2 | 2.244 | 13.21 | 2.331 | 18.61 |
| union number tag 1k | us/op | 47.86 | 2.235 | 12.93 | 2.61 | 17.74 |
| int tag record 1k | us/op | 47.23 | 0.985 | 12.36 | 3.017 | 19.11 |
| sha256 64 KB host bridge | MB/s | 2514 | 2626 | - | - | - |

### Where each row's gap comes from

Instructions per iteration, on the same main: Raiser counted at run time (a per-opcode counter applied to a probe
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

Commit `1b4eafd7173`, tree `d49e622c620`, builder msc `9f2ef7ed6b7`, 2026-11-04, load 7.6 before, 12.8 after (8
cores). Host flags `--mac --host m1m --cores 6`, with `--cc=clang` on the candidate build.

| row | unit | raiser | c | luajit-joff | luajit-jon | lua54 |
|---|---|---|---|---|---|---|
| int add loop 1k | us/op | 4.107 | 0.332 | 6.521 | 0.34 | 3.747 |
| float add loop 1k | us/op | 5.083 | 0.829 | 6.694 | 0.909 | 3.793 |
| int to float 1k | us/op | 10.49 | 0.851 | 6.088 | 0.337 | 3.621 |
| fib(25) recursion | us/op | 4265 | 292.9 | 3124 | 480.3 | 4170 |
| module variable read 1k | us/op | 12.45 | 0.65 | 6.825 | 0.34 | 3.973 |
| module object read 1k | us/op | 78.28 | 0.65 | 7.407 | 0.421 | 5.957 |
| field read/write 1k | us/op | 9.559 | 0.333 | 14.35 | 0.675 | 18.3 |
| ms call 1k | us/op | 23.95 | 0.33 | 10.39 | 0.523 | 17.05 |
| closure call 1k | us/op | 29.68 | 1.312 | 11.17 | 0.595 | 19.21 |
| Math.sqrt host call 1k | us/op | 92.73 | 4.96 | 11.29 | 5.173 | 15.87 |
| array push 1k | us/op | 12.96 | 1.653 | 8.571 | 1.646 | 9.028 |
| array index 1k | us/op | 10.03 | 0.539 | 8.139 | 0.607 | 4.89 |
| string concat 1k | us/op | 15.74 | 3.187 | 217.6 | 190.8 | 74.62 |
| Map set 1k | us/op | 817.2 | 8.796 | 14.47 | 2.199 | 6.24 |
| Map get 1k | us/op | 841.9 | 6.96 | 29.51 | 2.399 | 9.69 |
| object alloc 1k | us/op | 141.9 | 5.198 | 48.91 | 0.362 | 82.34 |
| sha256 64 KB host bridge | MB/s | 315.5 | 2142 | - | - | - |

Furthest from LuaJIT `-joff`: Map set (56x), Map get (29x), module object read (11x), Math.sqrt (8.2x), object alloc
(2.9x), closure call (2.7x); the Raiser is ahead on int add loop (0.63x), field read/write (0.67x), float add loop
(0.76x) and string concat. Furthest from `-jon`: object alloc (392x), Map set (372x), Map get (351x), module object
read (186x), closure call (50x), ms call (46x).
