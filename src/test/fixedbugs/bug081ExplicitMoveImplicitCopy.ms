// bug081 — `move x` silently degraded to a copy instead of erroring. The
// reference raises errFailedMove at the COPY DECISION: `inEnsureMove` is
// incremented while walking the move argument, and every genCopy/passCopyToSink
// under that flag errors "cannot move 'x', which introduces an implicit copy"
// (injectdestructors.nim genCopy + the sink-arg copy path). Our port asked
// `isLastReadSafe` at the wasMoved site instead — dead by construction, because
// the Consumed walk has ALREADY rewritten the argument into a sink temp by then
// and SymbolFlag.SinkTemp short-circuits the query to "safe".
//
// The diagnostic could not surface at all until analyze-phase errors started
// failing the build (the reason NIM-REF records errFailedMove as "abandoned").

import { compileToC } from "../helpers";

const degraded = `
class Foo {
	x: int32 = 1;
}

export function moveThenUse(): int32 {
	const a = new Foo();
	let b = new Foo();
	b = move a;
	return a.x + b.x;
}
`;

const genuine = `
class Foo {
	x: int32 = 1;
}

export function moveAtLastUse(): int32 {
	const a = new Foo();
	let b = new Foo();
	b = move a;
	return b.x;
}
`;

test "explicit move that would copy is rejected" {
	const c = compileToC(degraded);
	assert !c.ok, "expected an error, compiled clean";
	assert c.error.indexOf("cannot move 'a'") >= 0, "wrong message: " + c.error;
}

test "explicit move on a last use still compiles" {
	const c = compileToC(genuine);
	assert c.ok, "genuine move rejected: " + (c.ok ? "" : c.error);
}
