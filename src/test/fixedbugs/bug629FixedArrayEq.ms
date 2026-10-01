// Symptom: `==` on two fixed arrays `T[N]`, top level or as a struct field, failed at clang on C (`invalid operands to binary expression`) and compared the two arrays by reference on JS; `!=` likewise.
// Root cause: nothing lowered `==` on a fixed array: it reached codegen as the native operator, and `!=` was not derived for it.
// Fix: a fixed array compares element by element through a generated per-type Eq, as Nim's `==`[I, T] on arrays does (comparisons.nim:309); `!=` expands to `not ==` as for structs.
// Runtime on every lane: corpus 666.
import { compileToJS } from "../helpers";

const SRC = `
struct Cell { a: uint8; s: string; }
struct Row { cells: Cell[2]; }
function same(x: uint8[4], y: uint8[4]): boolean { return x == y; }
function differ(p: uint8[4], q: uint8[4]): boolean { return p != q; }
function sameRow(r: Row, t: Row): boolean { return r == t; }
const k: uint8[4] = [1, 2, 3, 4];
const row: Row = { cells: [{ a: 1, s: "p" }, { a: 2, s: "q" }] };
console.log(same(k, k), differ(k, k), sameRow(row, row));
`;

function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
		|| c == "_" || c == "$";
}

function calleeOf(out: string, args: string): string {
	const at = out.indexOf(args, 0);
	if (at < 0) return "";
	let start = at;
	while (start > 0) {
		if (!isIdentChar(out.charAt(start - 1))) break;
		start -= 1;
	}
	return out.slice(start, at);
}

function comparedByEq(out: string, args: string): string {
	const callee = calleeOf(out, args);
	if (!callee.endsWith("Eq")) return `${args} calls '${callee}'; `;
	if (out.indexOf("function " + callee + "(", 0) < 0) return `'${callee}' is not defined; `;
	return "";
}

test "bug629: == and != on a fixed array call its generated Eq (JS)" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		const failure = comparedByEq(r.value, "(x, y);") + comparedByEq(r.value, "(p, q);")
			+ comparedByEq(r.value, "(a.cells, b.cells)");
		assert failure == "", failure;
	}
}

test "bug629: a fixed array's Eq compares every element (JS)" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		const eq = calleeOf(r.value, "(x, y);");
		const at = r.value.indexOf("function " + eq + "(", 0);
		const body = at < 0 ? "" : r.value.slice(at, r.value.indexOf("\n}", at));
		const loops = body.indexOf(" < 4", 0) >= 0;
		assert loops && body.indexOf("a[", 0) >= 0 && body.indexOf("b[", 0) >= 0, body;
	}
}
