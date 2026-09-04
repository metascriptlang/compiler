// @maxrss: 40
// @stdout: leak-new-callarg acc=
// note: FIXED by inject.ms processNew (the NewExpr sibling of leak-callarg-object). A fresh `new T(...)` passed inline as a non-sink call arg the callee stores leaked (rc=0 stuck) — processNew captured the constructor ARGS but never the `new` RESULT. Was 124MB @ 2M (found by post-fix coverage probing). processNew now ensureDestructions the result in Normal mode (mirrors processObjectLiteral; the ctor owns the object's fields so destroy is balanced). Now flat ~2MB drc+orc. Nim 889.

// leak-new-callarg — fresh `new T(...)` as a stored call argument (the NewExpr sibling of
// leak-callarg-object). A `new` heap object passed inline as a non-sink call arg that the callee
// stores leaked (value stuck at rc=0): processNew captured the constructor ARGS but never the
// `new` RESULT itself, so a fresh heap object in a Normal (non-consumed) position was never
// captured for scope-exit destroy. Was 124MB @ 2M.
//
// FIXED by inject.ms processNew: Normal-mode ensureDestruction on the result (mirrors
// processObjectLiteral; the ctor already owns the object's fields so destroy is balanced —
// Reference parity injectdestructors:889). Now flat ~2MB.

class Payload { v: number; constructor(n: number) { this.v = n; } }
interface Box { p: Payload; }

function wrap(pp: Payload): Box { return { p: pp }; }

function main(): void {
	let acc = 0;
	for (let i = 0; i < 2000000; i = i + 1) {
		const b = wrap(new Payload(i % 7));
		acc = ((acc + b.p.v) % 100) as int32;
	}
	console.log(`leak-new-callarg acc=${acc}`);
}
main();
