// nim-guard: serial code that owns the graph may write the AST through a symbol
//
// INVARIANT (PARALOCK E24): the write refusal belongs to views. Outside a spawn
//   a Symbol is not a view, so `s.declNode.<field> = ...` is an ordinary write.
//
// WHAT IT CATCHES: a graph-specific write ban returning, which refused this
//   serial write with "cannot write through a type/symbol back-edge into the
//   AST" before f60457526's deep propagation made it unnecessary.
//
// LIMIT: std has no Symbol factory, so the write is built and emitted but not
//   executed; the call stays behind a null that is never taken.
//
// RED MEANS: serial meta code lost a write the owned graph allows.

import { Symbol } from "std/meta/node";

function relabel(s: Symbol): void { s.declNode.variantSlot = 1; }

const none: Symbol | null = null;
if (none != null) relabel(none);
console.log("GUARD-OK");
