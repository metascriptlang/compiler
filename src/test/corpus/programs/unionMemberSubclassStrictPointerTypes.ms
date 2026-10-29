// @stdout: mid 1 mid 2 mid 3 mid 4

@passC("-Werror=incompatible-pointer-types");

class Base { constructor() {} }
class Mid extends Base {
	v: number;
	constructor(v: number) { super(); this.v = v; }
}
class Leaf extends Mid {
	constructor(v: number) { super(v); }
}

function show(x: Mid | string): string {
	if (typeof x === "string") return x;
	return "mid " + x.v.toString();
}

function showNullable(x: number | Mid | null): string {
	if (x == null || typeof x === "number") return "none";
	return "mid " + x.v.toString();
}

function load(): Mid | string { return new Leaf(4); }

const held: Mid | string = new Leaf(2);
const maybe: number | Mid | null = new Leaf(3);
console.log(show(new Leaf(1)), show(held), showNullable(maybe), show(load()));
