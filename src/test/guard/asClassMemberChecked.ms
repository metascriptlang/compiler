// nim-guard: `as` out of a union converts a class member by the object's own class
//
// INVARIANT (NIM-REF CK-136): converting a union to a class reads the class of the object held
//   in whichever member slot holds one, as an object conversion does (Nim `upConv`/`genOf`
//   test the object's type field): an up-conversion always passes, a down-conversion passes
//   when the object is an instance, null stays null on a nullable target, a non-object member
//   is rejected, on every backend. JS tests `instanceof` the target class.
//
// WHAT IT CATCHES: a conversion that reads the slot tag instead of the object (a Child reached
//   through a Base-typed value fails `as Child`, `as Base` fails on a held Child), or a nullable
//   class target that skips the check so a number comes out of `as Row | null` as a Row.
//
// RED MEANS: the object-slot projection (objectHolderSlots in fit.ms, guardObjectSlot in
//   unionProjectLower.ms) or the JS class test stopped matching. Run /trace-nim on them.
// GUARD-JS

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

class Other { tag: int32 = 5; }

class Base {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

class Child extends Base {
	k: int32;
	constructor(n: int32) { super(n); this.k = 3; }
}

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

function familyOf(k: int32): Base | Child | null {
	if (k == 0) { const b: Base = new Child(4); return b; }
	if (k == 1) return new Child(5);
	if (k == 2) return null;
	return new Base(6);
}

function bareFamilyOf(k: int32): Base | Child {
	if (k == 0) { const b: Base = new Child(4); return b; }
	return new Base(6);
}

function familyChild(k: int32): Child | null { return familyOf(k) as Child | null; }
function familyBase(k: int32): Base | null { return familyOf(k) as Base | null; }
function bareChild(k: int32): Child { return bareFamilyOf(k) as Child; }

function narrowedChild(k: int32): int32 {
	const u = bareFamilyOf(k);
	if (u instanceof Child) return u.k;
	return -1;
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
	const throughBase = familyChild(0);
	const held = familyChild(1);
	const up = familyBase(1);
	return a != null && a.value == 7 && b == null && c.value == 7 && d.value == 7
		&& e != null && e.value == 7 && f != null && f.tag == 5
		&& throughBase != null && throughBase.k == 3 && held != null && held.n == 5
		&& familyChild(2) == null && up != null && up.n == 5 && bareChild(0).n == 4
		&& narrowedChild(0) == 3 && narrowedChild(1) == -1;
}

function wrongPathsRejected(): boolean {
	let ok = true;
	when (js) {
		ok = rejected((): void => { carriedNullable(2); })
			&& rejected((): void => { carriedPlain(2); })
			&& rejected((): void => { plainPlain(1); })
			&& rejected((): void => { plainNullable(1); })
			&& rejected((): void => { twoNullable(0); })
			&& rejected((): void => { familyChild(3); })
			&& rejected((): void => { bareChild(1); });
	}
	return ok;
}

if (validPaths() && wrongPathsRejected()) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
