// @stdout: namespace call surface done

// One name carries two surfaces: a call (`String(x)`, `BigInt(s)`) and a set of
// statics reached through the same identifier (`String.fromCharCode`,
// `BigInt.asIntN`). Static extensions resolve by receiver NAME, so the surfaces
// coexist on a symbol that is a plain function — with no runtime object behind
// the name on either backend.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function callSurface(): boolean {
	let ok = check("String number", String(42) == "42");
	ok = check("String identity", String("abc") == "abc") && ok;
	ok = check("String bool", String(true) == "true") && ok;
	ok = check("BigInt from string", BigInt("255") == 255n) && ok;
	ok = check("BigInt round trip", BigInt("-7").toString() == "-7") && ok;
	return ok;
}

function staticSurface(): boolean {
	let ok = check("fromCharCode ascii", String.fromCharCode(65) == "A");
	ok = check("fromCharCode bmp", String.fromCharCode(9731) == "\u2603") && ok;
	ok = check("fromCharCode masks", String.fromCharCode(65601) == "A") && ok;
	ok = check("asIntN wide", BigInt.asIntN(64, 255n) == 255n) && ok;
	ok = check("asIntN narrow", BigInt.asIntN(8, 255n) == -1n) && ok;
	ok = check("asUintN keeps", BigInt.asUintN(8, 255n) == 255n) && ok;
	ok = check("asUintN wraps", BigInt.asUintN(8, 256n) == 0n) && ok;
	return ok;
}

function bothSurfacesInterleave(): boolean {
	const b = BigInt("300");
	const narrowed = BigInt.asUintN(8, b);
	let ok = check("interleave value", narrowed == 44n);
	ok = check("interleave to string", String(narrowed) == "44") && ok;
	ok = check("interleave char", String.fromCharCode(44) == ",") && ok;
	return ok;
}

function main(): int32 {
	let ok = callSurface();
	ok = staticSurface() && ok;
	ok = bothSurfacesInterleave() && ok;
	if (!ok) { return 1; }
	console.log("namespace call surface done");
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
