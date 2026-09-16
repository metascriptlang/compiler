// Parity program — a value of type `T | null` compares the way TypeScript compares
// it, in a macro body and at runtime alike: a local, a helper's return value and
// an enum payload all equal their own value, and only the absent one equals null.
//
// @stdout: TTTTTF|TTTTTF
// @exit: 0

import { Node, NodeKind } from "std/meta";

enum Tone { Low, High }

function pickInt(): int32 | null { return 42; }
function pickText(): string | null { return "ok"; }
function pickTone(): Tone | null { return Tone.High; }

function report(n: int32 | null, s: string | null, h: int32 | null, t: Tone | null, none: int32 | null): string {
	return (n == 42 ? "T" : "F") + (s == "ok" ? "T" : "F") + (h == 42 ? "T" : "F")
		+ (t == Tone.High ? "T" : "F") + (none == null ? "T" : "F") + (h == null ? "T" : "F");
}

macro maybeAtCompileTime(v: Node): Node {
	const n: int32 | null = 42;
	const s: string | null = "ok";
	const h: int32 | null = pickInt();
	const t: Tone | null = pickTone();
	const none: int32 | null = null;
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: report(n, s, h, t, none) } as Node;
}

const n: int32 | null = 42;
const s: string | null = pickText();
const h: int32 | null = pickInt();
const t: Tone | null = pickTone();
const none: int32 | null = null;
console.log(maybeAtCompileTime(0) + "|" + report(n, s, h, t, none));
