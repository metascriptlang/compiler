// @exit: 1
// @stdout: before 3
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

class Base {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

class Child extends Base {
	k: int32;
	constructor(n: int32) { super(n); this.k = 3; }
}

function familyOf(k: int32): Base | Child | null {
	if (k == 0) { const b: Base = new Child(4); return b; }
	if (k == 2) return null;
	return new Base(6);
}

function familyChild(k: int32): Child | null { return familyOf(k) as Child | null; }

function show(c: Child | null): string { return c == null ? "null" : `${c.k}`; }

console.log(`before ${show(familyChild(0))}`);
console.log(`after ${show(familyChild(3))}`);
