# TypeScript oracle

This optional lane measures **pre-emit diagnostic compatibility**, not full TypeScript compatibility. It does not change the compiler, enable a default gate, or execute the upstream programs. Type/symbol baselines, declaration/JS emission and runtime behavior remain unmeasured.

The external source and executable oracle are pinned separately in `pin.json`. `upstream.mjs` executes the pinned harness's `TestCaseParser`, `getFileBasedTestConfigurations` and option parser, rather than replacing their fixture syntax with a second parser. The external anchors are `src/harness/harnessIO.ts`, `src/harness/harnessUtils.ts` and `src/testRunner/compilerRunner.ts` at that pin. Fetched source and package license notices stay with their artifacts under `out/compat/typescript/`.

## Run from the repository root

Node 24, `tar` and a POSIX host are required. Provisioning downloads verified archives into `out/`; it does not install a global package or alter the project dependencies.

```sh
node src/test/compat/typescript/run.mjs fetch
node src/test/compat/typescript/run.mjs inventory
node --test src/test/compat/typescript/core.test.mjs src/test/compat/typescript/upstream.test.mjs
node src/test/compat/typescript/run.mjs run --only tests/cases/compiler/arrayLiteral1.ts
```

`run.mjs` owns the CLI options and defaults. `--source` can read another verified snapshot; `--oracle` or `TS_ORACLE_MODULE` can name an identical executable oracle. `--msc` or `MSC` names the subject, separate from the Node process running the harness. With neither, the subject is the repository's `./msc` when present, otherwise installed `msc`.

A run is bounded to ten variants by default. `--only` selects exact upstream file names or configuration IDs; `--limit` selects a prefix; `--all` explicitly requests the full inventory. None of these reduces the report denominator. No `any`, feature or known-failure allowlist is applied.

Exit 0 means an inventory/provisioning command succeeded, or a full run matched every pre-emit diagnostic case. A partial run, a compatibility gap or an unverified negative result exits 1. Infrastructure/integrity failures exit 2. Passing harness self-tests do not make a compatibility survey green.

## Reading evidence

The inventory preserves every upstream configuration ID. A run writes a journal, per-case process/input receipts and `report.json` under its output directory. Reusing an output directory is refused rather than overwriting evidence. `plan.json` preserves the initial subject/support identities and exact selection before execution. An interrupted journal without a final report is not a verdict. SIGINT/SIGTERM cancellation and timeouts request group cleanup, then escalate after 500 ms; named controls cover direct and nested cooperative runners. External SIGKILL and host failure cannot run cleanup.

`core.mjs` owns outcome accounting. In particular, **both compilers rejecting is not diagnostic equivalence**: until structured subject diagnostics can be matched faithfully, those cases stay `both-reject-unverified`, outside `diagnostics-match`. The reported match fraction is a lower bound for this measured surface over the full pinned denominator, not a percentage of the TypeScript language.

`prepareCase` owns the adapter's declared limits. Shapes it cannot faithfully stage—such as multi-root CLI programs, virtual projects/symlinks, path-dependent harness settings, triple-slash file references and ambient subject project manifests—remain `harness-unsupported` entries, not exclusions or compiler failures. Extend one only with an oracle comparison and a deliberately broken control that proves the distinction. The oracle filesystem is case-sensitive and restricted to staged inputs plus the pinned standard declarations; subject resolution remains the subject compiler's real behavior.

The report identifies the subject binary and resolved support trees by content; `findSupportRoot` follows the compiler's four-ancestor marker search. Cwd-only installations are refused because the case runs in a different cwd. It does not assume a copied builder was compiled from the current Git tip. A changed source snapshot, oracle or subject/support tree invalidates the run rather than inheriting a prior verdict.

Subprocess execution currently requires a POSIX host and has been checked on macOS only. Windows execution is refused until process-tree supervision is implemented and verified there. Running this lane is not a release or a compiler safety verdict.

## Measured bootstrap evidence

On code tree `e2b6da427568f244bdc4a7cd2a30d7ba46b40fe0` with the pinned 5.9.2 corpus/oracle, inventory produced **12,373 files / 13,672 configurations**. Focused verification reported **73 pass, 0 fail, 0 skipped** in 30.99 seconds on the shared Mac. It included independent direct-`tsc` comparisons, accept-all/reject-all/crashing subjects, filesystem isolation, integrity, direct/nested cancellation, forced escalation and evidence/accounting failures. Removing the both-reject, harness-hash and CLI-hash guards in temporary copies made their named controls fail.

The 22-variant pilot at `out/compat/typescript/pilot-ready/report.json` recorded **2 diagnostics-match, 5 false-reject, 3 false-accept, 10 both-reject-unverified, 2 harness-unsupported and 13,650 not-run**. It took 24.27 seconds inside the survey and 30.23 seconds including startup/inventory on the shared Mac. This is a selected pilot, not a representative pass rate or a full-lane time estimate. The report's binary/support hashes identify the subject; compiler gaps were not fixed here.
