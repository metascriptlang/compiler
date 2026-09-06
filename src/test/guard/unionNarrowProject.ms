// Union narrowing must project/inject the active member on the C backend.
// Pre-fix: check passes but C codegen emits the whole msUnion struct where the
// narrowed member is expected (4 clang errors), and a string arg reaches a
// union param as bare msString* (silent UB, warning only).
// Real program on purpose: compileToC* harnesses cannot see codegen-stage
// errors (guard-harness-false-green). The Fake ledger balance covers the
// projection's copy-out cells (msAllocTyped + FakeCopy per ref-member narrow).
// GUARD-BALANCE Fake
// GUARD-JS

interface Fake { tag: string; }
function tn(s: string): Fake { return { tag: "#text:" + s }; }

function insA(v: string | Fake): Fake {
	if (typeof v == "string") { return tn(v); }
	return v;
}

function insB(v: string | Fake): Fake {
	if (typeof v == "string") { return tn(v as string); }
	return v as Fake;
}

// Function scope on purpose: top-level consts and discarded call results have
// no scope-exit destroy (pre-existing, measured on a no-union control), which
// would mask the projection cells this balance is meant to watch.
function main(): void {
	const n: Fake = { tag: "div" };
	const a = insA("a");
	const b = insA(n);
	const c = insB("b");
	const d = insB(n);
	console.log(a.tag);
	console.log(b.tag);
	console.log(c.tag);
	console.log(d.tag);
}
main();
console.log("GUARD-OK");
