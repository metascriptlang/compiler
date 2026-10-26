# Raiser VM — bytecode executor

The VM that runs Raiser bytecode: `@comptime` blocks and macros, and whole programs under `msc run --target=raiser`. AST → bytecode is `src/codegen/raiser/` (its own CLAUDE.md). Roles, memory model, std tiers, measured status and what is not built: [`docs/RAISER.md`](../../docs/RAISER.md).

## Files

| File | Holds |
|------|-------|
| `bytecode.ms` | `RaiserOpcode`, `RaiserInstruction`, ABC / ABx / Ax operand helpers |
| `value.ms` | `RaiserValue`, array, object and string heaps (rc, color, free list), `rcIncref` / `rcDecref`, `copyGraph` |
| `valueCopy.ms` | `copyTypedValue`: runs the copy plans `CopyValue` carries |
| `module.ms` | `RaiserFunction`, `RaiserModule` |
| `regs.ms` | register layout: class inference and the operand verifier; a register number is its slot in the frame, and a call site names where the callee frame begins |
| `memory.ms` / `vmString.ms` / `vmSeq.ms` | VM memory at host addresses (regions, size-class heap, ref cell header), the string cells and the typed array cells (`{len, p, meta, base}` over a `{cap, data}` payload, element width in `meta`, a view pointing into its base payload) built on it |
| `ledger.ms` | live-0 audit: finds heap items whose count exceeds the references that remain |
| `vm.ms` | dispatch loop, strands and scheduler, futures, safepoints, loop budget |
| `orc.ms` | `orcRegisterCandidate` / `orcCollect`: the registered-root cycle collector |
| `context.ms` | persistent context across module executions: the embedding API |
| `hostRegistry.ms` / `marshal.ms` | `CallHost` name → function table; box / unbox at the host boundary |
| `disasm.ms` | bytecode printer |

## Rules

- **The VM knows no AST** — `src/raiser/` never imports a node type; codegen hands it a `RaiserModule`.
- **Dispatch is one `switch (op)` in `vm.ms` over packed instruction words, one arm per opcode** — the `while (true)` around it is marked `@computedGoto`, so the C backend jumps through a table of label addresses.
- **Every program runs placed** — the bytecode carries every count (`RcInc`, `RcDec`, `WasMoved`, `DestroyValue`); the VM only holds and releases box shells. `comptime` (the macro engine, the default of `createVM` and `execModule`) skips timers, spawn and the ledger audit; the CLI and `createContext(false)` run with the audit, which in a build that keeps the ledger collects the registered cycle roots once right before it.
- **A string is an msString value in VM memory** — its handle is the address of the (len, payload) pair with the heap kind in the low bits; run-time strings are counted cells on the strand's `VmMemory`, constants sit in the process-wide constant segment, and read-only operations run the C string runtime on the stored value in place. Text reaches a host function only through `unboxString` and returns through `boxString`.
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
