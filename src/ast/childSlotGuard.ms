// nim-guard: AST child slots — a traversal callback must never see a null child
//
// INVARIANT (Nim): every child slot holds a NODE; absence is an `nkEmpty` node,
//   never nil. The parser fills both optional slots of an nkIdentDefs
//   unconditionally — `parser.nim:1078` (no `:` type) and `parser.nim:1086`
//   (no `=` initializer) each `result.add(newNodeP(nkEmpty, p))` — and sem then
//   tests the KIND, never nil (`semstmts.nim:970` `if def.kind == nkEmpty`).
//   That is why Nim's traversals dereference `n[i]` unconditionally.
// NIM-REF: §0 anti-flip heuristic — AST shape is the loosely-tracked structural
//   zone, so MS's nullable child slot is DIVERGE-INTENTIONAL. The divergence
//   transfers an obligation: with absence encoded as `null` instead of a
//   sentinel node, `forEachChild` must normalize it away. Otherwise every one of
//   its ~20 consumers has to remember the guard, and one forgetting is a
//   segfault, not a type error.
//
// WHAT IT CATCHES: `forEachChild` (src/ast/visitor.ms) handing `cb` a null.
//   `let v: uin` with no initializer leaves `initializer === null`; the LSP's
//   `isInTypeAnnotation` walker read `child.typeExpr` off it and the language
//   server died mid-request (EXC_BAD_ACCESS at 0xb8) — see bug075.
//
// RED MEANS: the null-skip in `forEachChild` was removed, or a new child table
//   bypasses it. Restore the skip — do NOT patch the callers one by one; the
//   whole point of the wrapper is that a caller cannot be expected to remember.
//
// Sibling of childTableGuard.ms: that one is STATIC (every Node-typed field is
// mentioned by every table), this one is RUNTIME (no table hands out a null).

import { parseSourceLenient } from "../parser/statements/validation";
import "../parser/statements/core";
import { forEachChild } from "./visitor";
import { Node, NodeKind, VariableDeclData } from "./node";

// Every construct here has at least one ABSENT optional child slot.
const SLOT_CORPUS = `let a: int32;
let b = 1;
function f(x: int32): void {
	if (x > 0) { return; }
	while (x > 0) { break; }
	try { f(x - 1); } finally { }
}
`;

function parseCorpus(): Node {
	const pr = parseSourceLenient(SLOT_CORPUS);
	if (!pr.ok) return null as unknown as Node;
	return pr.value;
}

// Walks the whole tree, counting how many times a callback is handed a null.
// Dereferences every non-null child so the traversal is real work, not a no-op.
function countNullChildren(root: Node): number {
	let nulls = 0;
	let kinds = 0;
	forEachChild(root, (child: Node): void => {
		if (child === null) {
			nulls = nulls + 1;
			return;
		}
		if (child.kind === NodeKind.Program) kinds = kinds + 1;
		nulls = nulls + countNullChildren(child);
	});
	return nulls;
}

// Vacuity check: the corpus must actually CONTAIN an absent slot, else the
// guard passes for the wrong reason. Same lesson as childTableGuard's
// "extractor still finds the AST field set".
function countAbsentInitializers(root: Node): number {
	let absent = 0;
	if (root.kind === NodeKind.VariableDecl) {
		const d = root.data as VariableDeclData;
		if (d.initializer === null) absent = absent + 1;
	}
	forEachChild(root, (child: Node): void => {
		if (child === null) return;
		absent = absent + countAbsentInitializers(child);
	});
	return absent;
}

test "child-slot guard: the corpus parses" {
	const program = parseCorpus();
	assert program !== null, "SLOT_CORPUS no longer parses — the guard would pass vacuously";
}

test "child-slot guard: the corpus still holds an absent child slot" {
	const program = parseCorpus();
	const absent = countAbsentInitializers(program);
	assert absent >= 1,
		"no VariableDecl with a null initializer left in SLOT_CORPUS — the guard has lost its teeth";
}

test "child-slot guard: no child table hands a null to its callback" {
	const program = parseCorpus();
	const nulls = countNullChildren(program);
	assert nulls === 0,
		"forEachChild handed a callback " + nulls.toString() + " null child(ren) — restore the null skip in visitor.ms, do not patch callers";
}
