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

function main(): void {
	let ok = true;

	if (render() !== "T1") ok = false;
	if (render() !== "T1") ok = false;
	if (render() !== "T1") ok = false;

	if (renderArrow() !== "T2") ok = false;
	if (renderArrow() !== "T2") ok = false;

	if (builds !== 2) ok = false;

	if (ok) {
		console.log("macro-expr-hoist PASS");
	} else {
		console.log("macro-expr-hoist FAIL builds=" + builds.toString());
	}
}

main();
