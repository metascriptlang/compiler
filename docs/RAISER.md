# Raiser VM — design & status

**This file is retired.** The single source of truth for Raiser is
[`src/raiser/CLAUDE.md`](../src/raiser/CLAUDE.md): the four product roles
(comptime / IDE eval / embeddable / game-logic), the two-regime memory model
(arena + ORC), the performance roadmap (Phases 0–5), the execution budget,
and the std-access tier model. Codegen-side architecture lives in
[`src/codegen/raiser/CLAUDE.md`](../src/codegen/raiser/CLAUDE.md); the VM's
position in the pipeline in [`docs/PIPELINE.md`](PIPELINE.md).

Why retired: this document was written 2026-03-05 against a role-1-only
vision (comptime engine only, arena-only memory, a "HashLink era" roadmap)
and contradicted the maintained CLAUDE.md on all three. Its still-valuable
ideas were folded forward before retirement:

| Was here | Now lives in |
|---|---|
| Post-transform AST pipeline ("Metaprogramming Parser" vision) | src/raiser/CLAUDE.md §Pipeline Position |
| Phase 5 execution safety (`opLimit`, instruction budget) | implemented 2026-09-04 as the **back-edge iteration budget** (`loopLimit`, CLI `--max-vm-iterations`) — src/raiser/CLAUDE.md §Execution budget |
| Phase 5 std bridge (readFile/writeFile/exec host bindings) | `src/compiler/meta/hostTable.ms` (MS host table + `src/raiser/hostRegistry.ms`); mechanism described in docs/PIPELINE.md §CallHost |
| Phase 5 diagnostic stack traces / Result-driven VM | still open — roadmap candidate |
| Phase 6 fixed-offset bytecode (`LoadFieldOffset`) | roadmap Phase 2 (field offsets) |
| Phase 6 monomorphic codegen | roadmap Phase 2/3 |
| Phase 6 `Call0`–`Call4`, `CallExtern` fnPtr bridge | roadmap Phase 5 (call-path work) |
