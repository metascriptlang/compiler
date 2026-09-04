// @xfail(esm): tree emit: native Promise.resolve shadowed by the emitted class Promise in _std/core/promise
// @maxrss: 40
// @stdout: leak-discarded-await done
// @serial
// note: Pins that a BARE `await h;` (result not bound) still destroys the awaited value. awaitLower's ExprStmt arm expanded the await and threw the result ident away, so the value never entered the AST and no scope-exit destroy was ever injected — the awaited value had no owner at all. Proven red on this exact program: 129 MB peak pre-fix vs 8.5 drc / 8.6 orc / 5.4 danger after (growth is linear in the loop bound, ~80 B/iter); the same leak reproduced on Arc, plain refs and strings alike, on Windows and Linux. The SAN lane CANNOT see it — the per-type ledger skips destroy==0 by design (run.ms parseLedgerFailure) and these types never reached a destroy at all — so this RSS cell is the only lane that catches the class.

// A bare `await h;` discards the RESULT, not the ownership: the awaited value carries the
// caller's reference exactly as in `const r = await h`, so it must be destroyed at scope exit.
// awaitLower binds the discarded result to a synthetic owned local for that reason; the ordinary
// DRC vardecl path then moves + destroys it, and the emitted C matches the bound form.
//
// Three shapes, because the discard path dispatches on the awaited inner type:
//   - string  (unboxed via the string reader)
//   - ref     (pointer-shaped, passes through unboxed)
//   - void    (nothing to own — must stay a no-op, not a bogus void binding)

interface Payload { tag: string; n: int32; }

function mkString(i: int32): string { return "discarded-await-payload-" + i.toString(); }
function mkRef(i: int32): Payload { return { tag: "discarded-await-payload", n: i }; }

function main(): void {
	for (let i = 0; i < 800000; i = i + 1) {
		const k = i % 7;
		const hs = spawn(() => mkString(k));
		await hs;
		const hr = spawn(() => mkRef(k));
		await hr;
		const hv = spawn(() => {});
		await hv;
	}
	console.log(`leak-discarded-await done`);
}
main();
