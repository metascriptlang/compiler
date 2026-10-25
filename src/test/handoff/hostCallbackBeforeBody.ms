import { compileToCWithStd, compileProjectToCWithStd, MapEntry } from "../helpers";
import { engineCompiledNames } from "../../codegen/raiser/eval";

test "a std routine with a host callback is called through it, never compiled from its body" {
	const before = engineCompiledNames().length;
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro stringCallbacks(node: Node): Node {
	const s = "  Hello, Callbacks  ";
	const v = s.trim() + "|" + s.trimStart().toUpperCase() + "|" + s.trimEnd().toLowerCase() + "|" + "ab".repeat(2) + "|" + "abc".reverse();
	if (v !== "Hello, Callbacks|HELLO, CALLBACKS  |  hello, callbacks|abab|cba") { error("callback mismatch: " + v, node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = stringCallbacks(0);
	console.log(x);
}
`);
	assert result.ok, result.ok ? "" : result.error;
	const compiled = engineCompiledNames().slice(before);
	for (const name of ["trim", "trimStart", "trimEnd", "toUpperCase", "toLowerCase", "repeat", "reverse", "isSpaceByte", "clampIndex", "byteSlice"]) {
		assert !compiled.includes(name), `the body of '${name}' was compiled`;
	}
}

test "a user routine named like a std routine with a host callback runs its own body" {
	const entries: MapEntry[] = [
		{ entryPath: "callbacks/text.ms", entrySource: `
export class Box {
	label: string;
	constructor(label: string) { this.label = label; }
}

export function repeat(s: string, count: int32): string { return s + "#" + count.toString(); }
export function reverse(s: string): string { return "user:" + s; }
export function trim(this b: Box): string { return "box:" + b.label; }
` },
		{ entryPath: "callbacks/main.ms", entrySource: `
import { Node, NodeKind } from "std/meta";
import { Box, repeat, reverse, trim } from "./text";

export macro userRoutines(node: Node): Node {
	const v = repeat("ab", 2) + "|" + reverse("abc") + "|" + new Box(" x ").trim() + "|" + "ab".repeat(2) + "|" + " y ".trim();
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

console.log(userRoutines(0));
` },
	];
	const code = compileProjectToCWithStd(entries, "callbacks/main.ms");
	assert !code.startsWith("ERROR:"), code;
	assert code.contains("ab#2|user:abc|box: x |abab|y"), "the expansion is missing from the emitted C";
}
