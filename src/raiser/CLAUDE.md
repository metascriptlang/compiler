# Raiser VM — bytecode executor

The VM that runs Raiser bytecode: `@comptime` blocks and macros, and whole programs under `msc run --target=raiser`. AST → bytecode is `src/codegen/raiser/` (its own CLAUDE.md). Roles, memory model, std tiers, measured status and what is not built: [`docs/RAISER.md`](../../docs/RAISER.md).

## Files

| File | Holds |
|------|-------|
| `bytecode.ms` | `RaiserOpcode`, `RaiserInstruction`, ABC / ABx / Ax operand helpers |
| `value.ms` | `RaiserValue`, array and object heaps (rc, color, free list), `rcIncref` / `rcDecref`, `copyGraph` |
| `valueCopy.ms` | `copyTypedValue`: runs the copy plans `CopyValue` carries |
| `module.ms` | `RaiserFunction`, `RaiserModule` |
| `vm.ms` | dispatch loop, strands and scheduler, futures, safepoints, loop budget |
| `orc.ms` | `orcCollectCycles`: trial-deletion cycle collector |
| `context.ms` | persistent context across module executions: the embedding API |
| `hostRegistry.ms` / `marshal.ms` | `CallHost` name → function table; box / unbox at the host boundary |
| `disasm.ms` | bytecode printer |
| `repl.ms` | execution demo, run as a test |
| `spike/` | untagged-register prototypes; do not type-check on the current compiler |

## Rules

- **The VM knows no AST** — `src/raiser/` never imports a node type; codegen hands it a `RaiserModule`.
- **Dispatch is an `if` / `else if` chain in `vm.ms`, one arm per opcode** — not `match`: `break` / `continue` in an arm would target the generated switch, not the dispatch loop.
- **`gcMode` picks the memory regime per VM** — `createVM` and `createContext` default to `"arena"` (no refcount); `cmdRunRaiser` sets `"orc"`. RC and the cycle collector run only under `"orc"`.
- **Every value that crosses strand heaps goes through `copyGraph`** — `spawn` copies the closure env and the global slots into the new strand's heap, `futureComplete` copies the result into the future's own heap, the awaiting reader copies it out.
- **A parked strand rewinds to its `Await` and runs it again on resume** — no partial-instruction state is saved anywhere.
- **`Halt` with `b = 1` skips the strand drain** — that is `process.exit`; a plain `Halt` lets the remaining strands finish first.
- **The budget counts back-edges, not instructions** — `loopLimit` (default 10M, `--max-vm-iterations=<n>`) counts backward jumps; recursion is capped by `MAX_CALL_DEPTH`; `vmCallFunction` resets the count, so each macro call gets a fresh budget.
- **A std operation lands in the lowest tier that can express it** — VM opcode for representation only, host bridge in `src/compiler/meta/hostTable.ms` only with a written reason, portable MS otherwise.
- **`cmdRunRaiser` prints the program's output after the VM stops** — a run that hangs prints nothing; `timeout` it before reading silence as a crash.

## Tests

```bash
msc test src/raiser/value.ms           # heaps, RC, copyGraph
msc test src/raiser/vm.ms              # hand-built bytecode through the VM
msc test src/codegen/raiser/eval.ms    # parse → check → transform → codegen → VM
```
