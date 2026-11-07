// note: a generic callback parameter written as a bare type parameter borrows an owned element, so some, every and findIndex read a Vec<Owned<N>> without destroying an element, on C and JS alike.
// @stdout: some true every true idx 1 destroyed during 0
// @stdout: vec some true destroyed during 0
let destroyed = 0;
class N {
	v: int32 = 0;
	constructor(v: int32) { this.v = v; }
}
function onDestroy(this n: N): void { destroyed += 1; }

function make(v: int32): Owned<N> { return new N(v); }

function main(): void {
	const kids: Vec<Owned<N>> = [make(1), make(2), make(3)];
	const a = kids.some((k) => k.v > 2);
	const b = kids.every((k: N): boolean => k.v > 0);
	const i = kids.findIndex((k) => k.v == 2);
	console.log("some", a, "every", b, "idx", i, "destroyed during", destroyed);
	let vk: Vec<Owned<N>> = [];
	vk.push(make(4));
	vk.push(make(5));
	console.log("vec some", vk.some((k) => k.v == 5), "destroyed during", destroyed);
}
main();
