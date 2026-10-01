// nim-guard: `as` out of a union converts a class member only when the union holds it
//
// INVARIANT (NIM-REF CK-136): a checked conversion keeps the union's discriminator: a held Row
//   converts, null stays null on a nullable target, and any other member is rejected, on every
//   backend. JS has no tag, so a class member is tested with instanceof, and only when no other
//   member of the union could hold an instance of that class.
//
// WHAT IT CATCHES: a nullable class target that skips the checked conversion, so a number comes
//   out of `as Row | null` as a Row and reads undefined (native: the C build fails instead).
//
// RED MEANS: the nullable-class arm of the as-conversion stopped converting or stopped checking.
//   Run /trace-nim on the TypeAssertion arm in checkExprPass.ms and assertionPayload in fit.ms.
// GUARD-JS

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

class Other { tag: int32 = 5; }

function carriedOf(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return 9;
}

function plainOf(k: int32): number | Row {
	if (k == 0) return new Row(7);
	return 9;
}

function twoOf(k: int32): Row | Other {
	if (k == 0) return new Row(7);
	return new Other();
}

function carriedNullable(k: int32): Row | null { return carriedOf(k) as Row | null; }
function carriedPlain(k: int32): Row { return carriedOf(k) as Row; }
function plainPlain(k: int32): Row { return plainOf(k) as Row; }
function plainNullable(k: int32): Row | null { return plainOf(k) as Row | null; }
function twoNullable(k: int32): Other | null { return twoOf(k) as Other | null; }

function rejected(f: () => void): boolean {
	try {
		f();
	} catch (e) {
		return true;
	}
	return false;
}

function validPaths(): boolean {
	const a = carriedNullable(0);
	const b = carriedNullable(1);
	const c = carriedPlain(0);
	const d = plainPlain(0);
	const e = plainNullable(0);
	const f = twoNullable(1);
	return a != null && a.value == 7 && b == null && c.value == 7 && d.value == 7
		&& e != null && e.value == 7 && f != null && f.tag == 5;
}

function wrongPathsRejected(): boolean {
	let ok = true;
	when (js) {
		ok = rejected((): void => { carriedNullable(2); })
			&& rejected((): void => { carriedPlain(2); })
			&& rejected((): void => { plainPlain(1); })
			&& rejected((): void => { plainNullable(1); })
			&& rejected((): void => { twoNullable(0); });
	}
	return ok;
}

if (validPaths() && wrongPathsRejected()) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
