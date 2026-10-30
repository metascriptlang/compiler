// E2E C: a loop with no call and no header write reads its arrays through local Spans under --danger.

import { compileToC } from "../helpers";
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

test "loop span cache: a checked build keeps the heap cell" {
	const c = emitted(loopIn(FILL), false);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("dollarspan_"), "a checked build was rewritten";
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
