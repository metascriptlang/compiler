// @maxrss: 40
// @stdout: leak-ref-member-read done
// @skip-js: migrated from native/ — JS-lane audit pending
// note: FIXED by the analyzer HiddenDeref capture fix (inject.ms processNode HiddenDeref|HiddenAddr recursion). A fresh interface (heap Ref) returned and only a non-RC field read, with the call otherwise discarded, leaks ~555MB pre-fix: the member object lowers to HiddenDeref(call), and processNode's hand-written dispatch had no wrapper case (`_ => node`) so the walk stopped before the fresh call → ensureDestruction never captured it. A bare member-access ExprStmt is NOT covered by callHoist (not an assignment/vardecl/if/while), so ONLY the analyzer fix makes it flat. The Result-shaped leak-call-in-cond guard missed this class (Result uses sret, not a HiddenDeref pointer). Permanent regression guard — was 555MB leaking, now flat.

// Guards the analyzer HiddenDeref capture fix (inject.ms processNode HiddenDeref|HiddenAddr
// recursion).
//
// A fresh interface (heap Ref) is returned and only a NON-RC field is read, with the call
// result otherwise discarded. The member object lowers to `HiddenDeref(provide(i))`; before
// the fix processNode's hand-written dispatch had no HiddenDeref case (`_ => node`) so the walk
// stopped at the wrapper and ensureDestruction never saw the fresh call → the Box leaked once
// per read (~555MB at 2M). This is a position callHoist does NOT cover (a bare member-access
// ExprStmt is not an assignment / vardecl / if / while), so ONLY the analyzer fix makes it flat
// — which is exactly what this guards. The Result-shaped leak-call-in-cond guard missed this
// whole class because Result member access uses sret, not a HiddenDeref pointer.

interface Box { buf: string; active: boolean; }

function provide(i: number): Box {
	let s = "x";
	let j = 0;
	while (j < 6) { s = s + s; j = j + 1; }
	return { buf: s, active: i % 2 === 0 };
}

function main(): void {
	for (let i = 0; i < 2000000; i = i + 1) {
		provide(i).active;              // HiddenDeref(call) wrapper
		(provide(i) as Box).active;     // TypeAssertion(call) wrapper
	}
	console.log(`leak-ref-member-read done`);
}
main();
