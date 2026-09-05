// A captured binding owns exactly one storage slot, and a DIFFERENT binding
// that merely spells the same name owns its own.
//
// Reference: capture detection keys on symbol id (`capturedVars.incl(s.id)`,
// lambdalifting.nim:516) and env fields are looked up by `s.itemId`
// (`addField` → `lookupInRecord`, lowerings.nim:241) — its comment states that
// two distinct same-named captures legitimately get distinct fields. NIM-REF
// row 115 ("Lambda lifting: ancestor captures") carries the standing rule that
// every reader of a binding must resolve to that binding's one env; the
// 2026-09-05 addendum listed same-named shadows in nested blocks as the
// declared residual. This guard pins that residual closed.
//
// RED MEANS a shadowing binding is resolving through the outer binding's env
// slot again (wrong value, or a C build failure naming `_envP` in a function
// that has none) — run /trace-nim on lambda lifting's name-keyed rewrites.
// GUARD-JS

type ShadowThunk = () => int32;

function blockShadowInLoop(): string {
	const fns: ShadowThunk[] = [];
	const seen: int32[] = [];
	for (let i = 0; i < 3; i += 1) {
		let x = 100 + i;
		fns.push(() => x);
		{
			let x = 900 + i;
			seen.push(x);
			x = x + 1;
			seen.push(x);
		}
	}
	let out = "";
	for (const v of seen) { out = out + v.toString() + ","; }
	out = out + "|";
	for (const f of fns) { out = out + f().toString() + ","; }
	return out;
}

function blockShadowNoLoop(): string {
	let x = 100;
	const f = () => x;
	let got = "";
	{
		let x = 900;
		got = got + x.toString() + ",";
		x = x + 1;
		got = got + x.toString() + ",";
	}
	return got + "cap=" + f().toString();
}

function shadowInNestedArrow(): string {
	let b = 50;
	const fb = () => b;
	const inner = (): int32 => { let b = 700; return b; };
	return inner().toString() + "," + fb().toString();
}

function shadowInIfBlock(): string {
	let a = 100;
	const fa = () => a;
	let got = 0;
	if (a > 0) { let a = 900; got = a; }
	return got.toString() + "," + fa().toString();
}

function shadowWithoutCapture(): string {
	let out = "";
	for (let i = 0; i < 2; i += 1) {
		let x = 100 + i;
		{
			let x = 900 + i;
			out = out + x.toString() + ",";
		}
		out = out + x.toString() + ",";
	}
	return out;
}

function main(): void {
	const a = blockShadowInLoop();
	const b = blockShadowNoLoop();
	const c = shadowInNestedArrow();
	const d = shadowInIfBlock();
	const e = shadowWithoutCapture();
	console.log("blockShadowInLoop=" + a);
	console.log("blockShadowNoLoop=" + b);
	console.log("shadowInNestedArrow=" + c);
	console.log("shadowInIfBlock=" + d);
	console.log("shadowWithoutCapture=" + e);
	if (a !== "900,901,901,902,902,903,|100,101,102,") {
		throw "GUARD RED: a nested-block shadow aliased the captured loop-local, got=" + a;
	}
	if (b !== "900,901,cap=100") {
		throw "GUARD RED: a nested-block shadow overwrote the captured binding's env slot, got=" + b;
	}
	if (c !== "700,50") {
		throw "GUARD RED: a local inside a nested arrow resolved through the outer env, got=" + c;
	}
	if (d !== "900,100") {
		throw "GUARD RED: an if-block shadow aliased the captured binding, got=" + d;
	}
	if (e !== "900,100,901,101,") {
		throw "GUARD RED: shadowing without any capture changed meaning, got=" + e;
	}
	console.log("GUARD-OK");
}
main();
