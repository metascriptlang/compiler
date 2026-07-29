// @maxrss: 30
// @stdout: PASS:actor-heapstr
// @serial
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED (analyzer inject.ms: msMsgComplete* added to the sink-position list). A heap string returned from an actor CALL read back corrupted: the dispatch builds `const _result = getter(); msMsgComplete<T>(replyFut, _result);` and msMsgComplete* ESCAPES the value into the reply future (read later cross-thread by the awaiter). The analyzer hardcoded only msFutureCompleteT as a sink position, so the actor-reply completion value arg was treated as a non-consuming borrow: it passed _result raw AND destroyed _result at dispatch scope-exit → the future pointed at a freed buffer → UAF (emit-C: `msMsgCompleteString(fut, _result); ... msStringDecref(_result);`). Marking msMsgComplete*'s value arg (index 1) DrcMode.Consumed — the exact mechanism msFutureCompleteT already uses — makes the analyzer give the future its OWN owned value (copied into an escaping sink temp for the finally-protected local) and keep _result for its own cleanup (emit-C: `msStringCopy(&borrow, _result); msMsgCompleteString(fut, borrow); ... msStringDecref(_result);`). Same boundary-by-copy convention as actor args (msMsgSetString/msStringNew) and struct returns (msSinkBoxStruct memcpy+memset). Pony shares val cross-actor via ORCA refcount; MS copies sole-owner data across instead. Root proven by A/B emit-C probe: without the fix → raw pass + decref → `FAIL tag=[garbage]`; with the fix → copy-to-sink + decref → PASS.

// OPEN BUG (xfail) — heap-allocated string through an actor field corrupts.
//
// Found by this tier: setting an actor string field to a HEAP-concatenated
// value (not a string literal) and reading it back via an actor CALL returns
// garbage — the field aliases a freed/reused buffer. A string LITERAL round-
// trips fine, which is why paralock-nested (literal tag) passed and masked it.
// This is the std/http multi-WS broadcast string path (PARALOCK §7.6).
//
// Pre-existing at HEAD (verified by reverting the uncommitted actor WIP — still
// failed). Correctness bug: exits 0, leaks/crashes nothing, just returns the
// wrong string — so it is caught by expectStdout, not by exit/RSS. Drop the
// xfail when the actor heap-string transfer is fixed.

actor Box {
	tag: string = "";
	setTag(s: string): void { this.tag = s; }
	getTag(): string { return this.tag; }
}

function makeHeapStr(): string {
	let s = "topic-";
	s = s + "room-" + "payload";   // heap concat, not a literal
	return s;
}

function main(): void {
	const b = new Box();
	b.setTag(makeHeapStr());
	const t = await b.getTag();
	if (t !== "topic-room-payload") { console.log(`FAIL tag=[${t}]`); return; }
	console.log("PASS:actor-heapstr");
}
