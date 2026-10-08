# Csmith study — measured before building Smith

Everything here was measured on csmith `0cdc710315cfee9035e22ef4363ca479270d1934`
(clone path is machine-local, on the arc card), Release build + a
coverage-instrumented Debug build, 2026-10-04..05. Raw probe outputs lived in
`/tmp/csmith-study-20261004/` and are gone after reboot — this file is the
durable copy of every load-bearing number. Re-measure before changing any of
them; never edit from reading alone.

Secondary sources read: the PLDI'11 paper (Finding and Understanding Bugs in C
Compilers), the ISSTA'12 swarm paper (Groce et al.), regehr's articles on
C-Reduce and Frama-C. Paper numbers are cited as such, not ours.

## Generator and determinism

- Pipeline verified by source + coverage: `main` (RandomProgramGenerator.cpp)
  → probability tables + context filters → types → function worklist → blocks
  → statements/expressions → output. Header embeds seed + full argv
  (`OutputMgr::OutputHeader`) — the reproducibility contract Smith copies.
- **Filters are part of the RNG stream**: `DefaultRndNumGenerator::rnd_upto`
  redraws on filter rejection, consuming stream state. Measured on 10 seeds
  (coverage build): 165,968 `rnd_upto` calls, 29,033 rejected draws. So
  reproducibility = seed + full option vector, nothing less.
- **Termination is probabilistic, not proven**: `Statement::make_random`
  retries by unbounded recursion (Statement.cpp, the `if (s == 0) return
  make_random(...)` tail), `ExpressionVariable::make_random` loops
  `do/while(true)` over candidates. Hard caps that do bound the program:
  max-funcs (only eInvoke is filtered at cap), max-block-depth, leaf-forcing
  at max-expr-depth, and a block always makes exactly `max_block_size`
  statement attempts (`BlockProbability` keeps only `block_size()-1`, so the
  loop bound is fixed, not random).
- Coverage of the instrumented generator over 10 seeds: 59.26% lines /
  65.0% functions / 51.9% branches (125 source files, 18,055 lines). NOT
  exercised: DFS-exhaustive internals, KLEE/CREST extensions, volatile
  wrapper emission (`-DWRAP_VOLATILES`), bookkeeping internals.

## Safety machinery (two tiers, both observed live)

Tier 1 — generation-time abstract interpretation over facts + effects:

- A rejection was caught live (seed 4, breakpoint at `Block.cpp:708`): a loop
  body's fixed-point analysis failed, `errlog` ended "Analysis failed at
  g_159 with ExpressionVariable. reason invalid read through pointer /
  StatementAssign lhs"; statement 0 of 2 was deleted from the looping block
  (`post_creation_analysis` tail-deletion path) and generation finished with
  exit 0. Rollback is real and recovers.
- Mechanism call counts (same 10 seeds): `check_read_var` 40,454 ·
  `check_write_var` 6,436 · `find_fixed_point` 1,150 ·
  `post_creation_analysis` 967 · `FactMgr::restore_facts` 374 ·
  `build_invocation_and_function` 52.
- Direct API probe (`factProbe.cpp`, linked against csmith's own objects):
  a may-points-to set with two live targets is accepted; adding a single
  maybe-null target makes the pointer invalid; one maybe-dead (out-of-scope)
  branch makes it invalid; `Effect::has_race_with`: read/read no conflict,
  read/write on the same variable conflicts, disjoint variables don't. Sound
  may-semantics, exactly as documented.
- Loop closure triggers the global fixed point, capped at 8 iterations with
  an `assert(0)` beyond (heuristic bound, not a completeness guarantee).
  `FunctionInvocationUser::build_invocation_and_function` generates
  params-then-body so generation order = execution order — the discipline
  Smith keeps for closure/capture families.

Tier 2 — runtime guards: `safe_math` wrappers. Measured across function and
macro variants: `INT32_MAX+1 → INT32_MAX`, `INT32_MIN/-1 → INT32_MIN`,
`1<<32 → 1`, `7%0 → 7`, `UINT32_MAX*2 → 4294967294`; compiling with
`-DUNSAFE` removes the guards and UBSan aborts on the same program.

## Oracle

- **The CRC32 checksum is not injective**: two distinct uint64 values
  (`6174860738191498004`, `18421888561687596808`) both hash to `7B4EE60F`
  through the real `csmith.h` runtime (candidate found after 64,840 random
  draws, then verified by compiling and running the actual runtime). "Digests
  agree" ≠ "values agree".
- `scripts/compare_csmith_outputs.py` returns 0 (all green) when both
  generators fail identically (measured with a nonexistent-option arg): equal
  failure is not evidence of correctness.
- Papers, cited: no ground truth exists; no correlated wrong results across
  unrelated compilers were ever observed — voting works there. We still treat
  identical outputs on all lanes as strong-but-not-final.

## Driver

- `run_program` bails on: nonzero program exit ("unexpected ... PROGRAM
  FAIL, retval = 7" measured), missing checksum line ("BAILING -- no
  checksum"), timeout. `RunSafely` watchdog kills after the deadline and
  appends `exit <code>` to the output file.
- Classification verified with a planted divergence (one lane compiled with
  `-DNOT_PRINT_CHECKSUM`): `compiler_test.pl` reported "Total wrong-code
  errors found: 1"; the clean config reported 0.
- **Timeout ≠ bug**: 11 of 130 lane cells hit a 3 s deadline; one of those
  programs (arrays, seed 21) completed under a 20 s deadline on gcc-15 -O3
  and ASan with checksums matching the other lanes.

## Reduction

- Input: seed 2, `--concise --max-funcs 2` (3,765 bytes), failure = the
  unsafe variant trips UBSan "shift exponent too large for 32-bit type
  'int32_t'".
- **Loose predicate** (any oversized-shift error): reduced to 93 bytes — but
  the failure had drifted to a `uint64_t` shift; the predicate accepted a
  different bug than the one found.
- **Strict predicate** (pins `int32_t` + "too large for 32-bit"): reduced to
  99 bytes, `safe_lshift_func_int32_t_s_u(0, a)` with `uint64_t a =
  4073709551615`; safe build clean, unsafe build fails with the original
  int32 symptom. The predicate is the real design surface of reduction.
- `creduce`'s `reduce-pointer-level` pass crashed twice (clang_delta assert,
  `ReducePointerLevel.cpp:776` "Uncatched initializer!") — non-fatal; the
  reduction continued to a fixpoint. External reducer fragility is normal;
  Smith must not depend on any single pass.

## Swarm

- Model in `compare_csmith_outputs.py` / `random_test`: one `p ~ U(0,1)` per
  configuration, each feature independently on with probability `p`.
  Measured over 20,000 sampled configs (rng seed 1842, 24 features):
  P(arrays ∧ pointers) = 0.33365, P(arrays ∧ pointers ∧ structs ∧ volatiles
  ∧ math64) = 0.16785 — matches the closed forms 1/3 and 1/6. 768/20,000
  configs enable no feature at all.
- ISSTA'12, cited: one week of swarm found 104 distinct compiler crashes vs
  73 for the all-features default (+42%); feature suppression is real —
  pointers suppressed 41% of the bugs found, arrays 17%. Swarm belongs in
  Smith from slice 2, not as an add-on.

## Broken corners of the reference — do not copy

All reproduced on 0cdc710:

- `--dfs-exhaustive --max-exhaustive-depth 8` (and 12): SIGSEGV.
  `Function::make_first` (Function.cpp:470) calls
  `body->add_back_return_facts` with `body == null` after error −4
  (BACKTRACKING_ERROR) — confirmed under lldb.
- `--max-split-files 3`: emits `extern static` redeclarations; rejected by
  both clang and gcc-15 (`DefaultOutputMgr` writes `extern` prefixes over
  static globals in `rnd_globals.h`).
- `--step-hash-by-stmt`: emits uses of undeclared `print_hash_value`.
- `--coverage-test` without `--no-argc`: emits `argc`/`argv` uses with no
  parameter list; works only with `--no-argc`.
- `--float`: passes `float*` into `transparent_crc_bytes(char*)`; gcc-15
  rejects, clang accepts — backend-dependent validity.
- `--go-delta`, `--delta-input`, `--delta-monitor`, `--no-delta-reduction`:
  parse and are advertised in `-hh`, but no code consumes them (vestigial).
- `--reduce` is printed in `-hh` help but rejected as an invalid option.

## Port / avoid

Port: seed + full config embedded in the output; filters as part of the RNG
stream; params-then-body generation order; loop-closure re-analysis with
tail deletion; effect-conflict discipline as the analogue of
sequence-point safety; swarm feature vectors; interestingness predicate as
the design surface of reduction.

Avoid: digest-only oracles; equal-failure-is-green; timeout-is-bug; the
pointer-UB machinery (no analogue in a memory-safe language); copying the
CLI surface (several dead flags above).
