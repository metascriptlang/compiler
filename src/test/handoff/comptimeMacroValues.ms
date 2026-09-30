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
