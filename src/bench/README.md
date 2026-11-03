# src/bench — is it still fast

A bench answers a speed question; `src/test` answers a correctness question. A bench never fails, never runs in the
land gate or a lane, and is no edit-loop check. A slice that claims a speed change runs the bench of its area and
quotes the table; a release may run every bench. A bench is not a test because a speed threshold on the shared hosts
goes red on load alone (host load moved 12 to 52 during single crypto runs on 2026-11-03), and because its runs are
longer than any check the edit loop allows.

## An area

`src/bench/<area>/` holds:

- the MetaScript program, and a twin per foreign implementation it is compared with (`bench.node.mjs`, `.rs`, `.nim`),
  printing the same row names;
- `run.sh`, which builds the program with `MSC` (and `MSBENCH_BASE` for an A/B), runs every arm in turn for `ROUNDS`
  rounds and prints each row's median per arm; it prints the host, the commit and the load before and after;
- `baseline.md`, the recorded tables: host, commit, tree, load, and the command that produced them.

A shared runner waits for a second area whose `run.sh` repeats the first one's.

## Running

Every run is a heavy job: `~/metascript/.gate-host/run-remote.sh` with the cores the bench uses, never on this Mac.
An ARM number comes from m1m (Apple M1 Pro) only, through `run-remote.sh --mac`, with the guard
`sysctl -n machdep.cpu.brand_string | grep -q "M1 Pro"` first, because a fallback to the local M3 Max gives numbers
no baseline row is comparable with. `run-remote.sh` copies no `.git`, so pass `MSBENCH_COMMIT=<sha>`.

A compiler build-cost bench is a different question with its own runner: `src/bench/compiler/`, `docs/BUILD-PERF.md`.
