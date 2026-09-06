// bug013 — bare `return;` lost inside lambda body → wrong inferred return type
//
// Symptom:    A lambda with an early-return guard pattern compiled to C with
//             a `void*` return type, and the bare `return;` then triggered
//                 "non-void function 'dollarfn_anon_N_' should return a
//                  value [-Wreturn-mismatch]"
//             Hit by ion's command-builder when callbacks used the
//             standard "skip-on-mismatch then process" shape:
//                 listen("event", (n, p) => {
//                     if (n !== "x") return;
//                     handle(p);
//                 });
//
// Root cause: `checkReturnStmt` (src/checker/checkPass.ms) early-exited on
//             bare `return;` (no argument) without updating
//             `ctx.inferredReturn`. When the lambda's body contained only
//             bare returns + side-effect calls, `inferredReturn` stayed
//             Unknown after body-walk → `checkAnonymousFunction` returned
//             Unknown for the lambda's return type → codegen fell back to
//             `void*` for the lifted function's signature → C rejected
//             the bare `return;`.
//
// Fix:        On bare `return;`, signal void to the inference state under
//             the same "first return wins" rule used for typed returns.
//             Bare return is the user's explicit declaration that the
//             function returns nothing — capturing it makes downstream
//             type info match the user's intent. Aligns with Nim, where
//             a bare `return` in an auto-typed proc infers void.

function listen(event: string, cb: (n: string, p: string) => void): void {
	cb(event, "data");
}

test "bug013: lambda with early-return infers void return" {
	let captured = "";
	listen("x", (n, p) => {
		if (n != "x") return;
		captured = p;
	});
	assert captured == "data";
}

test "bug013: lambda with bare return only (no other returns) — still void" {
	let hit = false;
	listen("anything", (n, p) => {
		hit = true;
		return;
	});
	assert hit;
}

test "bug013: lambda with conditional bare return + fall-through — fall-through path runs" {
	let counter: int32 = 0;
	listen("not-skip", (n, p) => {
		if (n == "skip") return;
		counter = counter + 1;
	});
	assert counter == 1;
}
