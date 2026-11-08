// E2E C: a loop with no call and no header write reads its arrays through local Spans (a checked build: a loop that stores an element).

import { compileToC, builtModuleC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

function emitted(source: string, danger: boolean): string {
	const c = compileToC(source, hostTargetInfo(), false, true, danger);
	return c.ok ? c.value : "error: " + c.error;
}

function loopIn(body: string): string {
	return `
function f(a: int32[], out: int32[]): int32 {
	let n: int32 = 0;
	${body}
	return n;
}
const xs: int32[] = [1, 2, 3];
const ys: int32[] = [0, 0, 0];
console.log(f(xs, ys));`;
}

const FILL = "for (let i: int32 = 0; i < a.length; i++) { out[i] = a[i] * 2; n += out[i]; }";

test "loop span cache: a fill loop reads and writes through local spans" {
	const c = emitted(loopIn(FILL), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msSpan_int32_t dollarspan_"), "no span local for the arrays";
	assert c.includes("msSpanAccessUnchecked(dollarspan_"), "the loop does not index a span";
	assert !c.includes("msArrayAccessUnchecked("), "an element is still reached through the cell";
	assert c.split("(*a_p0).len").length == 2, "the length is read from the cell more than once";
}

test "loop span cache: a checked fill loop goes through spans and keeps every check" {
	const c = emitted(loopIn(FILL), false);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msSpan_int32_t dollarspan_"), "no span local for the arrays";
	assert c.includes("msSpanAccess(dollarspan_"), "the loop does not index a span";
	assert !c.includes("msSpanAccessUnchecked(") && !c.includes("msArrayAccessUnchecked("), "a checked build dropped a bound check";
	assert c.includes("msMulI32(") && c.includes("msAddAssign("), "a checked build dropped an overflow check";
}

test "loop span cache: a checked read-only loop keeps the heap cell" {
	for (const body of ["n += a[i];", "n += a[i] * out[i];"]) {
		const c = emitted(loopIn(`for (let i: int32 = 0; i < a.length; i++) ${body}`), false);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert !c.includes("dollarspan_"), `a checked read-only loop was rewritten: ${body}`;
	}
}

test "loop span cache: a checked mapped toArray fills through spans" {
	const source = "function f(a: int32[]): int32[] {\n\treturn a.values().map((x) => x * 2).toArray();\n}\nconsole.log(f([1, 2, 3]).length);\n";
	const c = builtModuleC("loopSpanCacheEmit", "maptoarray", source, []);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msSpanAccess(dollarspan_"), "the mapped loop does not index a span";
	assert c.includes("msMulI32("), "the callback lost its overflow check";
}

test "loop span cache: a push in the loop keeps the heap cell" {
	const c = emitted(loopIn("for (let i: int32 = 0; i < a.length; i++) { if (i == 1) a.push(9); n += a[i]; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a loop that pushes was rewritten";
	assert c.includes("msArrayAccessUnchecked("), "the element is not read through the cell";
}

test "loop span cache: a call that can reach the array keeps the heap cell" {
	const c = emitted(`
function shrink(a: int32[]): void { a.pop(); }
` + loopIn("for (let i: int32 = 0; i < a.length; i++) { shrink(a); n += 1; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a loop that calls was rewritten";
}

test "loop span cache: a length write through an alias keeps the heap cell" {
	const c = emitted(loopIn("const b = a; for (let i: int32 = 0; i < a.length; i++) { if (i == 1) b.length = 2; n += a[i]; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a loop that sets a length was rewritten";
}

test "loop span cache: an assignment of the array variable keeps the heap cell" {
	const c = emitted(loopIn("let cur = a; for (let i: int32 = 0; i < 2; i++) { n += cur[0]; cur = out; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a loop that reassigns its array was rewritten";
}

test "loop span cache: a loop with an inner loop is cached once, outside both" {
	const c = emitted(loopIn("for (let r: int32 = 0; r < 2; r++) { for (let i: int32 = 0; i < a.length; i++) n += a[i]; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msSpan_int32_t dollarspan_"), "no span local for the array";
	assert !c.includes("msArrayAccessUnchecked("), "an element is still reached through the cell";
}

const GUARD = "changed while iterating";

test "loop span cache: a for-of whose body cannot change the array drops the length guard" {
	const c = emitted(loopIn("for (const x of a) n += x;"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(GUARD), "the guard of a header-stable loop is still emitted";
}

test "loop span cache: nested for-of loops over one array drop both guards" {
	const c = emitted(loopIn("for (const x of a) { for (const y of a) n += x * y; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes(GUARD), "a guard of the nested loops is still emitted";
}

test "loop span cache: a for-of that pushes keeps the length guard" {
	const c = emitted(loopIn("for (const x of a) { if (x == 1) a.push(9); n += x; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes(GUARD), "the guard of a loop that pushes was dropped";
}

test "loop span cache: a for-of that sets a length through an alias keeps the length guard" {
	const c = emitted(loopIn("const b = a; for (const x of a) { if (x == 1) b.length = 2; n += x; }"), true);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes(GUARD), "the guard of a loop that sets a length was dropped";
}

test "loop span cache: a checked build keeps the length guard" {
	const c = emitted(loopIn("for (const x of a) n += x;"), false);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes(GUARD), "a checked build lost the guard";
}

function closureLoop(closure: string, use: string): string {
	return emitted(`
function same(x: int32): int32 { return x; }
` + loopIn(`${closure} for (let i: int32 = 0; i < a.length; i++) { out[i] = ${use}; }`), true);
}

test "loop span cache: a call through a const closure that touches no array reads through local spans" {
	const c = closureLoop("const g = (x: int32): int32 => x * 2;", "g(a[i])");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msSpanAccessUnchecked(dollarspan_"), "a loop calling a closure that touches no array was not cached";
}

test "loop span cache: a const closure that captures keeps the heap cell" {
	const c = closureLoop("const g = (x: int32): int32 => x + n;", "g(a[i])");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a call through a closure with an env was admitted";
}

test "loop span cache: a call to a routine whose body touches no array header reads through local spans" {
	const callers: string[][] = [
		["", "same(a[i]) * 2"],
		["const g = (x: int32): int32 => same(x) + 1;", "g(a[i])"],
		["const g = (x: int32): int32 => { if (x > 9) return 9; return same(x); };", "g(a[i])"],
	];
	for (const k of callers) {
		const c = closureLoop(k[0], k[1]);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert c.includes("msSpanAccessUnchecked(dollarspan_"), k[0] + " " + k[1];
	}
	const recursive = emitted("function depth(x: int32): int32 { return x <= 0 ? 0 : 1 + depth(x - 1); }\n" + loopIn("for (let i: int32 = 0; i < a.length; i++) { out[i] = depth(a[i]); }"), true);
	assert !recursive.startsWith("error:"), recursive.slice(0, 400);
	assert recursive.includes("msSpanAccessUnchecked(dollarspan_"), "a recursive routine that touches no array was not admitted";
}

test "loop span cache: a call to a routine that changes an array keeps the heap cell" {
	const callers: string[] = [
		"const G: int32[] = [1, 2];\nfunction popped(x: int32): int32 { G.pop(); return x; }",
		"function grow(x: int32): int32 { const v: int32[] = []; v.push(x); return v.length; }",
		"const G: int32[] = [1, 2];\nfunction again(x: int32): int32 { if (x > 0) return again(x - 1) + 1; G.pop(); return 0; }",
	];
	const names: string[] = ["popped", "grow", "again"];
	for (let k = 0; k < callers.length; k++) {
		const c = emitted(callers[k] + "\n" + loopIn(`for (let i: int32 = 0; i < a.length; i++) { out[i] = ${names[k]}(a[i]); }`), true);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert !c.includes("dollarspan_"), callers[k];
	}
}

test "loop span cache: a const closure that reads an array argument keeps the heap cell" {
	const c = closureLoop("const g = (v: int32[]): int32 => v[0];", "g(a)");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a closure reading an array argument was admitted";
}

test "loop span cache: a let closure keeps the heap cell" {
	const c = closureLoop("let g = (x: int32): int32 => x * 2;", "g(a[i])");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a call through a reassignable closure was admitted";
}
