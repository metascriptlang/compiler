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

Commit `1b4eafd7173`, tree `d49e622c620`, builder msc `1caa3622619`, 2026-11-04, load 15.2 before, 9.9 after (32
threads). Host flags `--linux --host rtx --cores 16`.

| row | unit | raiser | c | luajit-joff | luajit-jon | lua54 |
|---|---|---|---|---|---|---|
| int add loop 1k | us/op | 2.188 | 0.196 | 3.049 | 0.485 | 2.127 |
| float add loop 1k | us/op | 2.999 | 0.347 | 2.268 | 0.347 | 2.27 |
| int to float 1k | us/op | 7.561 | 0.477 | 2.265 | 0.481 | 2.27 |
| fib(25) recursion | us/op | 2599 | 202.8 | 1702 | 274.9 | 2435 |
| module variable read 1k | us/op | 8.795 | 0.193 | 2.269 | 0.346 | 2.549 |
| module object read 1k | us/op | 59.63 | 0.194 | 3.003 | 0.347 | 3.738 |
| field read/write 1k | us/op | 7.49 | 0.208 | 7.752 | 0.404 | 11.34 |
| ms call 1k | us/op | 15.69 | 0.183 | 5.168 | 0.492 | 8.766 |
| closure call 1k | us/op | 19.03 | 1.144 | 6.771 | 0.492 | 10.4 |
| Math.sqrt host call 1k | us/op | 43.31 | 4.263 | 8.809 | 4.123 | 9.314 |
| array push 1k | us/op | 9.021 | 0.554 | 3.755 | 1.107 | 5.459 |
| array index 1k | us/op | 7.005 | 0.198 | 2.753 | 0.358 | 3.341 |
| string concat 1k | us/op | 12.28 | 0.863 | 146.5 | 116 | 35.1 |
| Map set 1k | us/op | 514.6 | 3.489 | 11.47 | 1.697 | 4.085 |
| Map get 1k | us/op | 510.7 | 2.43 | 13.49 | 1.754 | 6.738 |
| object alloc 1k | us/op | 91.64 | 1.161 | 32.77 | 0.496 | 54 |
| sha256 64 KB host bridge | MB/s | 350.9 | 2635 | - | - | - |

Furthest from LuaJIT `-joff`: Map set (45x), Map get (38x), module object read (20x), Math.sqrt (4.9x), module
variable read (3.9x), int to float (3.3x); the Raiser is ahead on int add loop (0.72x) and string concat, and even on
field read/write. Furthest from `-jon`: Map set (303x), Map get (291x), object alloc (185x), module object read
(172x), closure call (39x), ms call (32x).

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
