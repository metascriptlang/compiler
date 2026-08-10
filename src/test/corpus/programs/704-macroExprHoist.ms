// @stdout: macro-expr-hoist PASS
// note: a macro invoked at an EXPRESSION position emitting a statement ahead of its value. The macro returns SpliceMany: the last element is the value that replaces the call site, the ones before it are hoisted into the enclosing statement list. Runtime proof the unit guard (fixedbugs/bug103) cannot give — it only sees the emitted C. If the prefix were not hoisted at all, `tpl` would be undefined; if it were hoisted but re-run per call (the storage class not surviving the macro bridge, i.e. the `flags` whitelist dropping StaticStorage), `builds` would reach 3 and the three reads would differ. The slot is string-typed on purpose: an int-typed slot needs no cleanup and stays green even when module-scope storage is still queued for scope-exit destroy, which is the failure this shape exists to catch. Parity C↔JS is the point — the macro expands in the compile-time VM, so both backends must receive the same hoisted AST and reach the same answer.

import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				flags: NodeFlag.StaticStorage,
				declName: "tpl",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "buildTemplate" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tpl" },
		],
	};
}

let builds: int32 = 0;

function buildTemplate(): string {
	builds = builds + 1;
	return "T" + builds.toString();
}

function render(): string {
	const v = memo();
	return v;
}

// A SECOND expansion of the same macro, and inside an arrow body — the shape a
// component tree produces. Both hoisted decls are spelled `tpl` and neither
// carries a source position of its own, so a slot name mangled from the
// declaration alone collides and the C fails to compile with a redefinition.
// Each site must get its own module-scope slot, hence its own initializer run.
const renderArrow: () => string = (): string => {
	const v = memo();
	return v;
};

// Third shape: the VALUE element carries an arrow with a statement body, and
// the slot is read back through the closure that arrow ends up in. The two
// shapes above cannot catch a prefix inserted into the wrong statement list,
// because their value is a bare Identifier with no nested list to land in —
// the prefix has nowhere else to go. Here it does: checking the value descends
// into the wire arrow's body before returning to the list holding the call
// site, so a hoist bound to "whichever statement list drains first" lands
// INSIDE the wire and leaves the slot empty at mount time. A nested list in the
// PREFIX is deliberately not tested — it is checked before the prefix is
// queued, so it can never take it.
let wbuilds: int32 = 0;
let notes: int32 = 0;

function buildWired(): string {
	wbuilds = wbuilds + 1;
	return "W" + wbuilds.toString();
}

function noteWire(n: int32): void {
	notes = notes + n;
}

function mountWired(t: string, wire: (n: int32) => void): () => string {
	return (): string => { wire(1); return t; };
}

macro memoWired(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				flags: NodeFlag.StaticStorage,
				declName: "tplW",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "buildWired" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{
				kind: NodeKind.CallExpr,
				line: 0,
				column: 0,
				callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "mountWired" },
				arguments: [
					{ kind: NodeKind.Identifier, line: 0, column: 0, name: "tplW" },
					{
						kind: NodeKind.ArrowFunction,
						line: 0,
						column: 0,
						arrowParams: ["n"],
						arrowParamTypes: ["int32"],
						arrowFlags: "",
						arrowReturnType: "void",
						arrowBody: {
							kind: NodeKind.BlockStmt,
							line: 0,
							column: 0,
							statements: [{
								kind: NodeKind.ExprStmt,
								line: 0,
								column: 0,
								expr: {
									kind: NodeKind.CallExpr,
									line: 0,
									column: 0,
									callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "noteWire" },
									arguments: [{ kind: NodeKind.Identifier, line: 0, column: 0, name: "n" }],
								},
							}],
						},
					},
				],
			},
		],
	};
}

function renderWired(): string {
	const mount = memoWired();
	return mount();
}

function main(): void {
	let ok = true;

	if (render() !== "T1") ok = false;
	if (render() !== "T1") ok = false;
	if (render() !== "T1") ok = false;

	if (renderArrow() !== "T2") ok = false;
	if (renderArrow() !== "T2") ok = false;

	if (builds !== 2) ok = false;

	if (renderWired() !== "W1") ok = false;
	if (renderWired() !== "W1") ok = false;
	if (wbuilds !== 1) ok = false;
	if (notes !== 2) ok = false;

	if (ok) {
		console.log("macro-expr-hoist PASS");
	} else {
		console.log("macro-expr-hoist FAIL builds=" + builds.toString() + " wbuilds=" + wbuilds.toString() + " notes=" + notes.toString() + " wired=" + renderWired());
	}
}

main();
