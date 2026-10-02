// bug685 — bindSym of a generic function crashed msc
//
// Symptom:    a macro emitting `callee: bindSym("pick")` for a generic `pick` exited 139 with
//             no output when the call site did not import `pick`; with the import it was refused.
// Root cause: the literal path refused generic symbols and then left `bindSym("pick")` in the body,
//             so the run-time lookup ran in the call site's scope, missed, returned null, and the
//             null callee reached the checker.
// Fix:        a literal bound symbol may be generic and the call site instantiates it; a literal
//             that does not resolve stops the expansion; a null callee is an error, not a crash.

import { compileProjectToCWithStd, compileProjectToJSWithStd, checkProjectDiagnostics, MapEntry } from "../helpers";

function lib(binding: string): string {
	return `
import { Node, NodeKind, bindSym } from "std/meta";
export function pick<E>(witness: E, other: E): E { return witness; }
export function pick(witness: string, other: string): string { return witness + "!"; }
export function plain(witness: int32, other: int32): int32 { return witness + other; }
export macro first(x: Node): Node {
	${binding}
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column, callee: bound,
		arguments: [x, x], isDirectCall: false, resolvedOverloadIdx: -1 };
}
`;
}

const literalBinding = `const bound = bindSym("pick");`;
const computedBinding = `const name = "pi" + "ck"; const bound = bindSym(name);`;

function project(binding: string, main: string): MapEntry[] {
	return [
		{ entryPath: "test/lib.ms", entrySource: lib(binding) },
		{ entryPath: "test/main.ms", entrySource: main },
	];
}

const genericCall = `
import { first } from "./lib";
const value: int32 = 4;
const text: string = "a";
console.log(first(value), first(text), first<int32>(value));
`;

test "bug685: a literal bindSym of a generic instantiates at the call site on C and JS" {
	const entries = project(literalBinding, genericCall);
	const c = compileProjectToCWithStd(entries, "test/main.ms");
	assert c.indexOf("ERROR", 0) < 0, c;
	assert c.indexOf("pick", 0) >= 0, c;
	const js = compileProjectToJSWithStd(entries, "test/main.ms");
	assert js.indexOf("ERROR", 0) < 0, js;
}

test "bug685: a computed bindSym that misses is an error at the call, not a crash" {
	const main = `
import { first } from "./lib";
const value: int32 = 4;
console.log(first(value));
`;
	const missed = checkProjectDiagnostics(project(computedBinding, main), "test/main.ms");
	assert missed.join("\n").contains("null callee"), missed.join("\n");
	const imported = `
import { first, pick } from "./lib";
const value: int32 = 4;
console.log(first(value));
`;
	const found = checkProjectDiagnostics(project(computedBinding, imported), "test/main.ms");
	assert found.length == 0, found.join("\n");
}

test "bug685: an unresolved literal bindSym is one error naming it" {
	const main = `
import { first } from "./lib";
const value: int32 = 4;
console.log(first(value));
`;
	const literal = checkProjectDiagnostics(project(`const bound = bindSym("absent");`, main), "test/main.ms");
	assert literal.length == 1, literal.join("\n");
	assert literal[0].contains("bindSym cannot resolve 'absent'"), literal.join("\n");
}
