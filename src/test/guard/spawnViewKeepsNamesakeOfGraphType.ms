// nim-guard: an app class named like a compiler graph root is still a view inside a spawn
//
// INVARIANT (ULTRALOCK V5): a value a task reaches from a BORROW capture is a
//   view: no rc op, no root, no write. Only the compiler's own `Type`, `Symbol`
//   and `Node` from std/meta/node.ms are exempt from view propagation.
//
// WHAT IT CATCHES: the exemption matching by name alone. An app class called
//   `Type` then lost its view, the task counted the shared graph on eight
//   threads, and the per-thread collector trial-deleted it: 6/10 runs
//   crashed and 4/10 read out of bounds, while the same program with the
//   class renamed was refused here.
//
// RED MEANS: a namesake of a graph root is passed as a mutable value into a
//   callee from a spawn thunk, and the task races the parent's graph again.
//
// GUARD-CHECK-FAIL got Readonly<Type[]>, expected Type[]
// GUARD-CHECK-FAIL got Readonly<Symbol[]>, expected Symbol[]
// GUARD-CHECK-FAIL got Readonly<Node[]>, expected Node[]

class Type { kids: Type[] = []; back: Type | null = null; }
class Symbol { kids: Symbol[] = []; back: Symbol | null = null; }
class Node { kids: Node[] = []; back: Node | null = null; }

function countTypes(xs: Type[]): int32 { return xs.length as int32; }
function countSymbols(xs: Symbol[]): int32 { return xs.length as int32; }
function countNodes(xs: Node[]): int32 { return xs.length as int32; }

async function main(): Promise<void> {
	const types: Type[] = [new Type()];
	const symbols: Symbol[] = [new Symbol()];
	const nodes: Node[] = [new Node()];
	const a = spawn(() => countTypes(types));
	const b = spawn(() => countSymbols(symbols));
	const c = spawn(() => countNodes(nodes));
	console.log(`${await a}${await b}${await c}`);
}

await main();
