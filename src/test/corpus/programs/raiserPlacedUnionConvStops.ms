// @exit: 1
// @stdout: before row:7 base:4
// @xfail(danger): --danger drops the union tag test, so the read of the other member is undefined behaviour
// note: a checked `as` out of a union the Raiser tells apart by the held value refuses the members the target does not keep, as C does by the stored tag. Covered: a nullable source with a class and a number, a nullable class family, and a variant read through the other member's field. The last line is the refusal that stops the program.
class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}
class Base {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
class Child extends Base {
	k: int32;
	constructor(n: int32) { super(n); this.k = 3; }
}

function pick(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	return 9;
}
function rowOf(k: int32): Row | null { return pick(k) as Row | null; }

function family(k: int32): Base | Child | null {
	if (k == 0) return new Base(4);
	return new Child(5);
}
function baseOf(k: int32): Base | null { return family(k) as Base | null; }

const r = rowOf(0);
console.log("before " + (r == null ? "null" : "row:" + r.value.toString()) + " base:" + (baseOf(0) as Base).n.toString());
console.log("after " + (rowOf(1) == null ? "null" : "accepted"));
