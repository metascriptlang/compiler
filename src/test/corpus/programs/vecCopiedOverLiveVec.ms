// @stdout: 11tw0 33tw2 22tw1 22tw1 00-
// @stdout: 22tb1

class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}
struct Box { it: Item; tag: string; }

function mk(n: int32, p: string): Vec<Box> {
	let r: Vec<Box> = [];
	for (let i = 0; i < n; i += 1) r.push({ it: new Item(p + i.toString()), tag: "t" + p + i.toString() });
	return r;
}

function copyInto(dn: int32, sn: int32): string {
	const w = mk(sn, "w");
	let v = mk(dn, "v");
	v = w;
	return v.length.toString() + w.length.toString() + (v.length > 0 ? v[v.length - 1].tag : "-");
}

function nested(): string {
	const w: Vec<Vec<Box>> = [mk(1, "a"), mk(2, "b")];
	let v: Vec<Vec<Box>> = [mk(3, "c")];
	v = w;
	let u: Vec<Vec<Box>> = [mk(1, "d"), mk(1, "e"), mk(2, "f")];
	u = w;
	return v.length.toString() + u[1].length.toString() + w[1][1].tag;
}

console.log(copyInto(3, 1), copyInto(1, 3), copyInto(2, 2), copyInto(0, 2), copyInto(2, 0));
console.log(nested());
