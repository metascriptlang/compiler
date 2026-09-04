// @stdout: nullable stringify ok
//
// `T | null` over a value type is a Maybe carrier on the C backend. Every stringify
// path must show the payload (or "null") and never the carrier's own fields; the js
// lane, where the value is a native null, is the reference.

let calls: int32 = 0;

function effect(): string | null {
	calls = calls + 1;
	return "v";
}

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function main(): void {
	let ok = true;
	const s0: string | null = null;
	const s1: string | null = "hi";
	const n0: int32 | null = null;
	const n1: int32 | null = 42;

	console.log("cat " + s0 + " " + s1 + " " + n0 + " " + n1);
	console.log("tpl " + `${s0}` + " " + `${s1}`);
	console.log("echo:");
	console.log(s0);
	console.log(s1);
	console.log(n1);

	// The carrier is read twice by the lowering (present + value) but the operand
	// itself must be evaluated once.
	console.log("eff=" + effect());
	ok = check("singleEval", calls === 1) && ok;

	// Narrowing and equality keep working off the same carrier.
	if (s1 !== null) { ok = check("narrowRead", s1.length === 2) && ok; }
	ok = check("equality", s0 === null && s1 !== null) && ok;

	if (!ok) { console.log("nullable stringify FAILED"); return; }
	console.log("nullable stringify ok");
}

main();
