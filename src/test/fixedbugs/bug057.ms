// bug057 — on-demand macro helper compiles dropped their diagnostics
//
// A macro body calling a module-scope helper triggers ensureCompiledIntoEngine,
// which ran its own check pass and discarded the result: the helper's errors
// reached nobody. bug053 fixed the WRAPPER's error slot being clobbered by
// these compiles; the helpers' own silence stayed. eval.ms now queues helper
// errors and compileMacroIntoEngine merges them into the macro's result.

import { compileToCWithStd } from "../helpers";

test "bug057: a broken macro helper names itself in the diagnostic" {
	const src = `
import { Node, NodeKind } from "std/meta";

function bad(n: number): number {
	return noSuchFn(n);
}

export macro useBad(x: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: bad(2) };
}

function main(): void {
	console.log(useBad(1));
}
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	assert c.error.indexOf("Macro 'useBad' body: helper 'bad'", 0) >= 0;
	assert c.error.indexOf("evaluator unavailable", 0) >= 0;
}

test "bug057: a healthy macro helper adds no diagnostic" {
	const src = `
import { Node, NodeKind } from "std/meta";

function good(n: number): number {
	return n * 2;
}

export macro useGood(x: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: x.line, column: x.column, value: good(21) };
}

function main(): void {
	console.log(useGood(1));
}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
	assert c.value.indexOf("42", 0) >= 0;
}
