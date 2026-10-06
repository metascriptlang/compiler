// @exit: 1
// @stdout: before 4
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

function bareFamilyOf(k: int32): Base | Child {
	if (k == 0) { const b: Base = new Child(4); return b; }
	return new Base(6);
}

function bareChild(k: int32): Child { return bareFamilyOf(k) as Child; }

console.log(`before ${bareChild(0).n}`);
console.log(`after ${bareChild(1).k}`);
