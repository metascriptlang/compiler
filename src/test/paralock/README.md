# PARALOCK runtime test tier

Real C-compiled scenarios that exercise the three async primitives
defined in `docs/PARALOCK.md` — `async` / `await`, `spawn`, and `actor` —
both in isolation and in the load-bearing nested combinations.

The `lang/` tier validates **language semantics** for `async`/`await`
and spawn, but its assertions cannot prove the C runtime is actually
doing the right thing for actors or for cross-thread spawn completion.
This tier closes that gap: every scenario here is built with the C
backend and executed as a native binary.

## What each scenario validates

| Scenario                  | Mode coverage          | Hot spots                                              |
|---------------------------|------------------------|--------------------------------------------------------|
| `asyncOnly.ms`            | async                  | `await` cooperative yield, future chaining             |
| `spawnOnly.ms`            | spawn                  | parallel fan-out, AwaitGroup of N, result collection   |
| `actorOnly.ms`            | actor                  | SEND, CALL, string + int + ref args (Sendable + COPY)  |
| `asyncSpawnMix.ms`        | async + spawn          | `await spawn(...)` inside async function (Phase 4a)    |
| `actorWithAsync.ms`       | actor + async          | actor method awaits — cooperative actor suspend Phase 5|
| `actorWithSpawn.ms`       | actor + spawn          | spawn(...) inside actor method — PARALOCK §7 fan-out   |
| `deepNested.ms`           | actor + async + spawn  | three-way nesting: actor → async → spawn group         |

## Why these particular cases

PARALOCK invariants I1-I15 (see `docs/PARALOCK.md` §8) are the contract
the runtime + compiler must uphold. The scenarios target the cross-
cutting interactions — that's where regressions hide. In particular:

- `actorWithSpawn.ms` is the canonical Phase 5/§7 case (zero-copy
  fan-out from an actor method).
- `deepNested.ms` is the smallest realistic program that touches
  Pony-derived mailbox + AwaitGroup + cooperative actor suspend
  simultaneously.

## Pass/fail protocol

Each scenario prints exactly one `PASS: <name>` line on success and
non-zero stdout on any failed assertion. The runner script
(`runAll.sh`) builds each scenario via the C backend, runs it under
a timeout, and greps for the expected marker. The script exits
non-zero if any scenario fails to build, times out, crashes, or
omits the marker.

## Running

```bash
bash src/test/paralock/runAll.sh
```

Or single scenario for debugging:

```bash
msc build src/test/paralock/actorWithSpawn.ms
./out/debug/actorWithSpawn
```

## Adding new scenarios

1. Create `src/test/paralock/<name>.ms`. It must print exactly one
   `PASS: <name>` line and only that line on success.
2. Add the scenario to the `SCENARIOS` array in `runAll.sh`.
3. Document the coverage in the table above.

If a scenario depends on a runtime feature that is gated behind a
PARALOCK phase still in-progress (e.g. `#88`/`#89` cross-thread IO),
mark it `SKIP` in the runner script with a comment pointing at the
blocking issue.
