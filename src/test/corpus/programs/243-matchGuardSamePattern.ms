// @stdout: assign guardTrue=A-guarded
// Same-pattern arms with a `when` guard — first-match-wins. lowerMatch is a
// SHARED pass, so pre-fix BOTH backends ran the unguarded sibling after the
// guarded arm (assign mode: overwrote the result; stmt mode: ran both
// bodies). Byte-parity across lanes is therefore blind to this — the @stdout
// pin carries the contract, exactly like 216-matchShortCircuit.
// Guard spelled `when f` on purpose: `when (f) =>` trips a separate
// pre-existing parser bug (the guard swallows `(f) => body` as an arrow
// function) — reported, not fixed here.

enum K { A, B }

let n: int32 = 0;
function bump(): void { n = n + 1; }

function pickAssign(k: K, f: boolean): string {
	const r: string = match (k) {
		K.A when f => "A-guarded",
		K.A => "A-plain",
		K.B => "B",
	};
	return r;
}

function runStmt(k: K, f: boolean): int32 {
	n = 0;
	match (k) {
		K.A when f => { bump(); },
		K.A => { bump(); },
		_ => {},
	};
	return n;
}

function main(): void {
	console.log("assign guardTrue=" + pickAssign(K.A, true));
	console.log("assign guardFalse=" + pickAssign(K.A, false));
	console.log("assign B=" + pickAssign(K.B, true));
	console.log("stmt guardTrue runs=" + runStmt(K.A, true).toString());
	console.log("stmt guardFalse runs=" + runStmt(K.A, false).toString());
}

main();
