// bug204 — a field read under a type assertion, passed to a sink parameter, was not copied
//
// Symptom:    `xs.push(b.p!)` and `xs.push(b.p as Thing)` pushed `(*b).p` with no incref; once `b`
//             was destroyed the array held a freed object (`plain=123`, `bang=11100`).
// Root cause: sink arguments were walked in Consumed mode and copied only when the OUTER argument
//             was a MemberExpr/ArrayAccess, so the assertion wrapper hid the field read.
// Fix:        sink arguments are walked in SinkArg mode, like the reference's call arguments; the
//             field read under any ownership-transparent wrapper makes its own copy.

import { compileToC } from "../helpers";

const src = `
interface Thing {
	_x: number;
}

interface Box {
	p: Thing | null;
	q: Thing;
}

export function viaBang(b: Box, xs: Thing[]): void {
	xs.push(b.p!);
}

export function viaAs(b: Box, xs: Thing[]): void {
	xs.push(b.q as Thing);
}

export function bare(b: Box, xs: Thing[]): void {
	xs.push(b.q);
}

export function fromParam(t: Thing | null, xs: Thing[]): void {
	xs.push(t!);
}
`;

function fnBody(cCode: string, marker: string): string {
	const defStart = cCode.lastIndexOf(marker);
	if (defStart < 0) return "";
	const fromDef = cCode.slice(defStart, cCode.length);
	const end = fromDef.indexOf("\n}");
	if (end < 0) return "";
	return fromDef.slice(0, end);
}

function countIncrefs(body: string): number {
	let n = 0;
	let at = body.indexOf("msIncref");
	while (at >= 0) {
		n += 1;
		at = body.indexOf("msIncref", at + 1);
	}
	return n;
}

function increfsIn(fn: string): number {
	const c = compileToC(src);
	if (!c.ok) return -1;
	const body = fnBody(c.value, fn + "__");
	if (body.length == 0) return -1;
	return countIncrefs(body);
}

test "bug204: a field read under ! passed to a sink parameter increfs" {
	assert increfsIn("viaBang") == 1, "viaBang increfs: " + increfsIn("viaBang").toString();
}

test "bug204: a field read under as passed to a sink parameter increfs" {
	assert increfsIn("viaAs") == 1, "viaAs increfs: " + increfsIn("viaAs").toString();
}

test "bug204: a bare field read passed to a sink parameter keeps one incref" {
	assert increfsIn("bare") == 1, "bare increfs: " + increfsIn("bare").toString();
}

test "bug204: a borrowed param under ! passed to a sink parameter keeps one incref" {
	assert increfsIn("fromParam") == 1, "fromParam increfs: " + increfsIn("fromParam").toString();
}
