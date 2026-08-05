// bug078 — needsReturnIncref classified the RAW return expression, so a
// conversion wrapper (`return x as unknown as T`) fell into the unhandled-kind
// arm: the analyzer pushed an error that compile.ms never read (the dropped
// post-check diagnostics class) and the C shipped WITHOUT the incref. A
// member read returned through a cast handed the caller an unowned pointer —
// the caller's scope decref stole a count from the field's owner (UAF class).
// Reference: ownership flows through conversions ("ownership invariance",
// injectdestructors.nim nkConv/nkHiddenStdConv/nkCast recurse into the operand
// with the same mode) — classify the operand, never the wrapper.
//
// Cells assert on the EMITTED C per function: the wrapper must be ownership-
// transparent, so member-under-cast gains msIncref, call-under-cast stays a
// bare owned transfer, and param-under-cast keeps exactly the one incref the
// Consumed walk already synthesizes (no double-incref cascade).

import { compileToC } from "../helpers";

const src = `
interface Thing {
	_x: number;
}

interface Box {
	p: Thing;
}

extern function makeThing(): Thing from "makeThing";

export function fromField(b: Box): Thing {
	return b.p as unknown as Thing;
}

export function fromCall(): Thing {
	return makeThing() as unknown as Thing;
}

export function fromParam(t: Thing): Thing {
	return t as unknown as Thing;
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

test "member read returned through a cast increfs for the caller" {
	const c = compileToC(src);
	assert c.ok, "compile failed: " + (c.ok ? "" : c.error);
	const body = fnBody(c.value, "fromField__");
	assert body.length > 0, "fromField not emitted";
	assert countIncrefs(body) === 1, "fromField increfs: " + countIncrefs(body).toString();
}

test "owned call result returned through a cast stays a bare transfer" {
	const c = compileToC(src);
	assert c.ok, "compile failed";
	const body = fnBody(c.value, "fromCall__");
	assert body.length > 0, "fromCall not emitted";
	assert countIncrefs(body) === 0, "fromCall increfs: " + countIncrefs(body).toString();
}

test "param returned through a cast keeps exactly one incref" {
	const c = compileToC(src);
	assert c.ok, "compile failed";
	const body = fnBody(c.value, "fromParam__");
	assert body.length > 0, "fromParam not emitted";
	assert countIncrefs(body) === 1, "fromParam increfs: " + countIncrefs(body).toString();
}
