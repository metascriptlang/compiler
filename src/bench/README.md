# src/bench — is it still fast

A bench answers a speed question; `src/test` answers a correctness question. A bench never fails, never runs in the
land gate or a lane, and is no edit-loop check. A slice that claims a speed change runs the bench of its area and
quotes the table; a release may run every bench. A bench is not a test because a speed threshold on the shared hosts
goes red on load alone (host load moved 12 to 52 during single crypto runs on 2026-11-03), and because its runs are
longer than any check the edit loop allows.

## An area

`src/bench/<area>/` holds:

- `bench.ms`, and `bench.node.mjs` (or `bench.lua`) as its twin, printing the same row names; both time each row through the
  shared harness (`src/bench/harness.ms`, `src/bench/harness.mjs`; `bench.lua` carries its own copy): three rounds of
  at least 250 ms, the median and its spread;
- `baseline.md`, the recorded tables: host, commit, tree, load, and the command that produced them.

An area that compares against something other than node lists its arms in `arms` (default `candidate node`):
`candidate` or `c` is `bench.ms` on C `--release`, `raiser` is `msc run --target=raiser bench.ms`, `node` runs
`bench.node.mjs`, and `luajit-joff`, `luajit-jon` and `lua54` run the Lua twin `bench.lua` under LuaJIT 2.1 and Lua
5.4, which `src/bench/buildLua.sh` builds from pinned sources into `out/bench/lua/` on first use.

`src/bench/run.sh <area> [rounds]` builds `bench.ms` with `MSC` (and, with `MSBENCH_BASE`, the area's first arm again
as `base` for an A/B), runs every arm in turn for `rounds` rounds and prints each row's median per arm; it prints the
host, the commit and the load before and after.

## Running

Every run is a heavy job: `~/metascript/.gate-host/run-remote.sh` with the cores the bench uses, never on this Mac.
An ARM number comes from m1m (Apple M1 Pro) only, through `run-remote.sh --mac`, with the guard
`sysctl -n machdep.cpu.brand_string | grep -q "M1 Pro"` first, because a fallback to the local M3 Max gives numbers
no baseline row is comparable with. `run-remote.sh` copies no `.git`, so pass `MSBENCH_COMMIT=<sha>`.

A compiler build-cost bench is a different question with its own runner: `src/bench/compiler/`, `docs/BUILD-PERF.md`.
