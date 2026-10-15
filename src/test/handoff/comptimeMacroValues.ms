import { compileToCWithStd } from "../helpers";

test "comptime macro values: string indexing feeds deterministic hashing" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro hashName(node: Node): Node {
	const s = "padding:8px;";
	let h: int64 = 5381;
	for (let i = 0; i < s.length; i += 1) {
		h = (h * 33 + s.charCodeAt(i)) % 4294967296;
	}
	if (("n_" + h.toString()) !== "n_1325208689") { error("comptime value mismatch", node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: "n_" + h.toString() };
}

function main(): void {
	const x = hashName(0);
}
`);
	assert result.ok, result.ok ? "" : result.error;
}

test "comptime macro values: shared string and byte operations compose" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro strfeat(node: Node): Node {
	const s = "Hello, MetaScript!";
	const a = s.trim().toLowerCase().repeat(2);
	const parts = a.split(",");
	const probe = s.byteSlice(0, 5).asBytes().asString();
	const found = s.indexOf("Meta");
	const n = s.count("l");
	let v = "FAIL";
	if (s.startsWith("Hello")) {
		if (s.endsWith("!")) {
			if (s.contains("Meta")) {
				v = probe + found.toString() + n.toString() + parts.length.toString();
			}
		}
	}
	if ((v) !== "Hello723") { error("comptime value mismatch", node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = strfeat(0);
	console.log(x);
}
main();
`);
	assert result.ok, result.ok ? "" : result.error;
}

test "comptime macro values: byte search and slice keep their edge results" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro byteEdges(node: Node): Node {
	const s = "hello";
	const got = [
		s.byteIndexOf("l").toString(), s.byteIndexOf("l", 3).toString(), s.byteIndexOf("l", 4).toString(),
		s.byteIndexOf("", 2).toString(), s.byteIndexOf("o", -5).toString(), s.byteIndexOf("h", 9).toString(),
		s.byteLastIndexOf("l").toString(), s.byteLastIndexOf("l", 2).toString(), s.byteLastIndexOf("").toString(),
		s.byteLastIndexOf("hello!").toString(), s.byteSlice(1, 3), s.byteSlice(3, 99), s.byteSlice(2, 1),
		s.byteAt(1).toString(), s.byteAt(9).toString(), s.byteLength().toString(), "é".byteLength().toString(),
	].join(",");
	if (got !== "2,3,-1,2,4,-1,3,2,5,-1,el,lo,,101,-1,5,2") { error("comptime value mismatch: " + got, node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: got };
}

function main(): void {
	console.log(byteEdges(0));
}
main();
`);
	assert result.ok, result.ok ? "" : result.error;
}

function lineCountSource(lines: int32): string {
	return `
import { Node, NodeKind } from "std/meta";

export macro lineCount(node: Node): Node {
	const text = "0123456789abcdef0123456789abcdef0123456789abcdef\\n".repeat(${lines});
	const n = text.split("\\n").length;
	if (n !== ${lines + 1}) { error("comptime value mismatch: " + n.toString(), node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: n.toString() };
}

function main(): void {
	console.log(lineCount(0));
}
main();
`;
}

test "comptime macro values: splitting a large string stays linear in its length" {
	compileToCWithStd(lineCountSource(10));
	const t0 = performance.now();
	const small = compileToCWithStd(lineCountSource(10));
	const t1 = performance.now();
	const large = compileToCWithStd(lineCountSource(1000));
	const t2 = performance.now();
	assert small.ok, small.ok ? "" : small.error;
	assert large.ok, large.ok ? "" : large.error;
	const extra = (t2 - t1) - (t1 - t0);
	assert extra < 4000, `splitting 49 KB into 1001 lines cost ${extra} ms more than 11 lines`;
}

test "comptime macro values: immutable module data is available" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

const TABLE = "ABC";
const WIDTH = 5 * 100;

export macro usesConst(node: Node): Node {
	const v = TABLE + "-" + WIDTH.toString();
	if ((v) !== "ABC-500") { error("comptime value mismatch", node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = usesConst(0);
	console.log(x);
}
main();
`);
	assert result.ok, result.ok ? "" : result.error;
}

test "comptime macro values: array mutation preserves order and length" {
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro arrfeat(node: Node): Node {
	const a: string[] = [];
	a.push("x");
	a.push("y");
	a.push("z");
	const last = a.pop();
	const second = a.at(1);
	a.splice(0, 1);
	a.push("w");
	const cap = a.capacity();
	const v = last + second + a[0] + cap.toString() + a.length.toString();
	if ((v) !== "zyy22") { error("comptime value mismatch", node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: v };
}

function main(): void {
	const x = arrfeat(0);
	console.log(x);
}
main();
`);
	assert result.ok, result.ok ? "" : result.error;
}

test "comptime macro values: literal accessors preserve kind and typed operations" {
	const cases = [
`
import { Node, NodeKind, childAt, isFloatLiteral, intValue, floatValue, stringValue } from "std/meta";

export macro readVals(node: Node): Node {
	const i = childAt(node, 0);
	const f = childAt(node, 1);
	const s = childAt(node, 2);

	if (isFloatLiteral(i)) { error("an integer literal must not report as float", node); }
	const iv = intValue(i);
	if (iv !== 8) { error("intValue read " + iv.toString() + ", want 8", node); }
	// Arithmetic and ordering go through the typed opcodes — this is what a
	// wrong register kind breaks while equality on the printed text still looks
	// right.
	if (iv + 1 !== 9) { error("intValue is not usable in arithmetic", node); }
	if (!(iv > 7)) { error("intValue is not usable in a comparison", node); }

	if (!isFloatLiteral(f)) { error("a fractional literal must report as float", node); }
	const fv = floatValue(f);
	if (fv !== 8.5) { error("floatValue read " + fv.toString() + ", want 8.5", node); }

	const sv = stringValue(s);
	if (sv !== "#334") { error("stringValue read '" + sv + "', want '#334'", node); }

	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: sv };
}

function main(): void {
	const x = readVals({ pad: 8, ratio: 8.5, color: "#334" });
}
`,
`
import { Node, NodeKind, childAt, isFloatLiteral } from "std/meta";

export macro checkDotZero(node: Node): Node {
	const n = childAt(node, 0);
	if (!isFloatLiteral(n)) { error("8.0 lost its float-ness crossing the wire", node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: "ok" };
}

function main(): void {
	const x = checkDotZero({ v: 8.0 });
}
`,
	];
	for (const source of cases) {
		const result = compileToCWithStd(source);
		assert result.ok, result.ok ? "" : result.error;
	}
}

function intValueOf(arg: string): string {
	const result = compileToCWithStd(`
import { Node, NodeKind, intValue } from "std/meta";
function f(): int32 { return 1; }
const x = 5;
macro iv(n: Node): Node { return { kind: NodeKind.StringLiteral, line: n.line, column: n.column, value: \`\${intValue(n)}\` }; }
console.log(iv(${arg}));
`);
	return result.ok ? "ok" : result.error;
}

test "comptime macro values: intValue refuses a node that is not an integer literal and names its kind" {
	assert intValueOf("x").includes("intValue needs an integer literal, got Identifier"), intValueOf("x");
	assert intValueOf("f()").includes("intValue needs an integer literal, got CallExpr"), intValueOf("f()");
	assert intValueOf("-5").includes("intValue needs an integer literal, got UnaryExpr"), intValueOf("-5");
	assert intValueOf("\"7\"").includes("intValue needs an integer literal, got StringLiteral"), intValueOf("\"7\"");
	assert intValueOf("8.5").includes("intValue needs an integer literal, got a float literal"), intValueOf("8.5");
	assert intValueOf("41") == "ok", intValueOf("41");
}

test "comptime macro values: intValue reads every bit of an integer literal" {
	const result = compileToCWithStd(`
import { Node, NodeKind, childAt, intValue, isFloatLiteral } from "std/meta";

export macro bits(node: Node): Node {
	const past53 = childAt(node, 0);
	const past63 = childAt(childAt(node, 1), 0);
	const top = childAt(childAt(node, 2), 0);
	if (intValue(past53) != 9007199254740993) { error("intValue lost the low bit past 2^53: " + intValue(past53).toString(), node); }
	if (isFloatLiteral(past63) || isFloatLiteral(top)) { error("a uint64 literal past 2^63 reports as float", node); }
	if (intValue(past63) != -9223372036854775807 - 1) { error("intValue of 2^63 is not its bit pattern: " + intValue(past63).toString(), node); }
	if (intValue(top) != -1) { error("intValue of 2^64-1 is not its bit pattern: " + intValue(top).toString(), node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: "ok" };
}

function main(): void {
	const x = bits({ a: 9007199254740993, b: 9223372036854775808 as uint64, c: 18446744073709551615 as uint64 });
}
`);
	assert result.ok, result.ok ? "" : result.error;
}
