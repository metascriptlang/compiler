// @stdout: A:2:1 B:5:bx B:5:bx A:2:1 1 bx
// @stdout: A:2:1 B:5:bx
// @stdout: A:2:1 B:5:bx C:cy:3 B:5:bx C:cy:3 A:2:1
// @stdout: a:2 b:5:bx b:5:bx a:2
// @stdout: end
// @exit: 0

struct Q { n: int32; }
struct A { v: int32[]; a: int32; }
struct B { v: Q; b: string; }
struct C { v: string; c: int32; }
type AB = A | B;
type ABC = A | B | C;

function show(x: AB): string {
	if ("a" in x) return `A:${x.v.length}:${x.a}`;
	return `B:${x.v.n}:${x.b}`;
}

function show3(x: ABC): string {
	if ("a" in x) return `A:${x.v.length}:${x.a}`;
	if ("b" in x) return `B:${x.v.n}:${x.b}`;
	return `C:${x.v}:${x.c}`;
}

function twoArms(): void {
	const one: AB = { v: [1, 2], a: 1 } as A;
	const two: AB = { v: { n: 5 }, b: "b" + "x" } as B;
	let c1: AB = one;
	let c2: AB = two;
	c1 = two;
	c2 = one;
	const keptA: A = one;
	const keptB: B = two;
	console.log(show(one), show(two), show(c1), show(c2), keptA.a, keptB.b);
	[c1, c2] = [c2, c1];
	console.log(show(c1), show(c2));
}

function threeArms(): void {
	const one: ABC = { v: [1, 2], a: 1 } as A;
	const two: ABC = { v: { n: 5 }, b: "b" + "x" } as B;
	const three: ABC = { v: "c" + "y", c: 3 } as C;
	let c1: ABC = one;
	let c2: ABC = two;
	let c3: ABC = three;
	c1 = two;
	c2 = three;
	c3 = one;
	console.log(show3(one), show3(two), show3(three), show3(c1), show3(c2), show3(c3));
}

struct TA { kind: "a"; v: int32[]; }
struct TB { kind: "b"; v: Q; b: string; }
type TAB = TA | TB;

function showTagged(x: TAB): string {
	if (x.kind == "a") return `a:${x.v.length}`;
	return `b:${x.v.n}:${x.b}`;
}

function tagged(): void {
	const one: TAB = { kind: "a", v: [1, 2] };
	const two: TAB = { kind: "b", v: { n: 5 }, b: "b" + "x" };
	let c1: TAB = one;
	let c2: TAB = two;
	c1 = two;
	c2 = one;
	console.log(showTagged(one), showTagged(two), showTagged(c1), showTagged(c2));
}

twoArms();
threeArms();
tagged();
console.log("end");
