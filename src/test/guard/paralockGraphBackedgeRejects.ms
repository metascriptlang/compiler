// nim-guard: a spawn thunk cannot write the AST through a borrowed type or symbol
//
// INVARIANT (PARALOCK E24, ULTRALOCK V5): a value reached from a BORROW capture
//   is a view however deep the chain goes, so the compiler's own graph edges
//   Symbol.declNode and Type.sym lead to Readonly<Node>, and a write through
//   that node is refused like any other write through a view.
//
// WHAT IT CATCHES: Readonly propagation stopping at the Type/Symbol graph again
//   (the shape it had before f60457526, when a separate back-edge ban stood in
//   for it), or a write path (assignment, ref argument, a closure inside the
//   thunk, a longer chain) that stops consulting the view.
//
// RED MEANS: one case below lost its refusal; the error count pins all five.
//
// GUARD-CHECK-FAIL cannot write through Readonly<Node>
// GUARD-CHECK-FAIL cannot pass an argument to a 'ref' or 'out' parameter through Readonly<Node>
// GUARD-CHECK-FAIL 5 type error(s) found

import { Symbol, Type } from "std/meta/node";

function setSlot(ref x: int32): void { x = 8; }

export async function direct(s: Symbol): Promise<int32> {
	const h = spawn(() => { s.declNode.variantSlot = 1; return 0; }); // GUARD-REFUSED
	return await h;
}

export async function refArg(s: Symbol): Promise<int32> {
	const h = spawn(() => { setSlot(s.declNode.variantSlot); return 0; }); // GUARD-REFUSED
	return await h;
}

export async function selfHostShape(t: Type): Promise<int32> {
	const h = spawn(() => { t.sym!.declNode.nodeType = null; return 0; }); // GUARD-REFUSED
	return await h;
}

export async function closureInWorker(s: Symbol): Promise<int32> {
	const h = spawn(() => {
		const relabel = () => { s.declNode.variantSlot = 2; }; // GUARD-REFUSED
		relabel();
		return 0;
	});
	return await h;
}

export async function deeper(s: Symbol): Promise<int32> {
	const h = spawn(() => { s.declNode.resolvedSym!.declNode.variantSlot = 3; return 0; }); // GUARD-REFUSED
	return await h;
}
