# Smith — design

Status: direction approved (2026-10-03..05, in conversation); implementation
not started. This file owns the agreed shape and the constraints that forced
it. Evidence for every claim lives in `CSMITH-STUDY.md`.

## Goal

Find `msc` bugs — wrong code across backends / GC modes / optimization,
compiler crashes, DRC ledger violations — by random differential testing:
generate deterministic MetaScript programs, run them through the existing
corpus lanes, record divergences as reproducible bundles, reduce them, and
graduate confirmed regressions into the corpus.

## Why this shape, and not another

- MetaScript is memory-safe by construction, so Csmith's hardest problem —
  keeping the generated program single-interpretation by avoiding undefined
  behavior — mostly disappears. Our analogue of "single interpretation" is
  **cross-lane determinism**: identical stdout on C-drc / C-orc / C-danger,
  JS and raiser, and a clean SAN ledger. The fact engine Smith needs is
  scope/lifetime for closures and captures — not may-points-to over pointer
  arithmetic.
- The corpus contract (`docs/TESTING.md`, `src/test/corpus/run.ms`) already
  defines the oracle surface: deterministic stdout, byte-compare across lanes,
  no golden files, no fuzzy matching. Smith emits programs that are
  corpus-conformant **by construction** and drives those lanes; it never grows
  a second oracle or a second runner.
- Three false signals were measured on the reference and are designed out
  here, not to be re-learned: digest oracles collide; equal-failure
  comparisons read green; timeouts are usually not bugs (CSMITH-STUDY
  §Oracle, §Driver).

## Components

1. **Generator** (`tools/smith/`, written in MetaScript): seed + feature
   vector → typed, scope-aware program that prints canonical deterministic
   output. The feature vector is a swarm configuration: each construct family
   independently on/off per run (CSMITH-STUDY §Swarm).
2. **Driver**: builds and runs each program on the corpus lanes (parity set;
   SAN lane for DRC questions; raiser optional), reusing corpus runner
   semantics and known-red. Divergence = first lane pair whose outputs differ,
   or any crash / sanitizer report.
3. **Failure bundle** under `out/smith/`: seed, feature vector, generator
   commit, `msc` build and support-tree commit, per-lane outputs, divergence
   pair. Rerunning must reproduce the byte-identical source and the same lane
   outcomes.
4. **Reducer**: `creduce --not-c` with an interestingness predicate that pins
   failure identity (lane pair + symptom + type/width axis). C-Reduce's README
   claims non-C support; that claim is unverified for `.ms` and verifying it
   is part of slice 4.
5. **Graduation**: a reduced, confirmed regression becomes a corpus program
   named by invariant; the bundle is then deleted.

## Non-goals

- Not a benchmark, not a parser fuzzer (random token soup tests nothing past
  the parser), not a std-API exerciser (the corpus owns that surface), not
  distributed.
- No vendored Csmith code — mechanisms only. The reference checkout path is
  machine-local and stays on the arc card.

## Slices

1. **Smallest closed loop**: generator for one family (integer/float
   arithmetic + control flow + canonical prints), lane run via the corpus
   runner, bundle on divergence. Proven on a planted divergence.
2. **Swarm + scope/lifetime families**: feature vectors; closures, captures,
   unions, generics — the constructs whose divergence yield we actually want.
3. **SAN lane**: DRC-ledger and sanitizer divergences as bundle kinds.
4. **Reduction**: `creduce --not-c` + predicate; graduate one failure
   end-to-end into the corpus.

## Open questions (design-level, decide before the slice that needs them)

- Canonical print vs digest as the lane-comparison surface: lean canonical
  print + byte-compare (the corpus contract), digest only as a bundle index —
  collision evidence in CSMITH-STUDY §Oracle.
- How the generator samples DRC-relevant lifetime shapes without becoming a
  second analyzer: start structural (capture graphs, deterministic drop
  order), measure divergence yield, add machinery only on evidence.

## Done when (arc)

- A bundle reruns byte-identically from its metadata alone.
- At least one planted divergence AND one real divergence have gone the full
  loop: detected → bundled → reduced → graduated into `src/test/corpus/`.
