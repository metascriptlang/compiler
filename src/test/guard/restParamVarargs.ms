// Rest parameters (`...rest: T[]`). Rest-ness is the type-level TypeKind.Varargs
// marker (Nim tyVarargs); the wrapper is transparent and every consumer must
// peel it. Array annotations resolve to Ref<Array<T>>, so peeling the wrapper
// takes TWO hops, not one — a single `.typeReturn` lands on Array<T> and the
// checker then compares a trailing argument against the array instead of the
// element. The same unpeeled wrapper reaches shimCallArg, where a Varargs
// formal is not pointer-shaped, so the packed array gets dereferenced and
// passed by value into a pointer parameter.

function joinStrings(head: string, ...rest: string[]): string {
	let s = head;
	for (const r of rest) { s = s + r; }
	return s;
}

function sumNumbers(base: number, ...rest: number[]): number {
	let total = base;
	for (const n of rest) { total = total + n; }
	return total;
}

function countRest(...rest: string[]): number {
	return rest.length;
}

function firstOr<T>(fallback: T, ...rest: T[]): T {
	for (const r of rest) { return r; }
	return fallback;
}

class Weighted {
	n: number;
	constructor(n: number) { this.n = n; }
}

function totalWeight(base: number, ...items: Weighted[]): number {
	let t = base;
	for (const it of items) { t = t + it.n; }
	return t;
}

function takesArray(head: string, xs: string[]): string {
	let s = head;
	for (const x of xs) { s = s + x; }
	return s;
}

class Joiner {
	sep: string;
	constructor(sep: string) { this.sep = sep; }
	join(head: string, ...rest: string[]): string {
		let s = head;
		for (const r of rest) { s = s + this.sep + r; }
		return s;
	}
}

function main(): void {
	const many = joinStrings("hello", "a", "b", "c");
	if (many !== "helloabc") { throw "GUARD RED: trailing args = " + many; }

	const none = joinStrings("hello");
	if (none !== "hello") { throw "GUARD RED: zero trailing args = " + none; }

	const one = joinStrings("x", "y");
	if (one !== "xy") { throw "GUARD RED: single trailing arg = " + one; }

	const nums = sumNumbers(1, 2, 3);
	if (nums !== 6) { throw "GUARD RED: numeric rest sum = " + nums.toString(); }

	const numsNone = sumNumbers(41);
	if (numsNone !== 41) { throw "GUARD RED: numeric rest with no trailing args = " + numsNone.toString(); }

	const c0 = countRest();
	if (c0 !== 0) { throw "GUARD RED: rest.length with no args = " + c0.toString(); }

	const c3 = countRest("a", "b", "c");
	if (c3 !== 3) { throw "GUARD RED: rest.length with three args = " + c3.toString(); }

	// The packed array must reach the callee as a pointer, exactly like an
	// ordinary array argument — this is the value/pointer shim path.
	const plain = takesArray("h", ["a", "b"]);
	if (plain !== "hab") { throw "GUARD RED: ordinary array parameter = " + plain; }

	// Method receiver occupies typeChildren[0], so the rest slot index shifts.
	const j = new Joiner("-");
	const joined = j.join("a", "b", "c");
	if (joined !== "a-b-c") { throw "GUARD RED: rest through a method receiver = " + joined; }

	const joinedNone = j.join("solo");
	if (joinedNone !== "solo") { throw "GUARD RED: method rest with no trailing args = " + joinedNone; }

	// Through a generic parameter — the rest element type is only concrete
	// after instantiation, and the wrapper still has to peel to T.
	const gStr = firstOr("z", "a", "b");
	if (gStr !== "a") { throw "GUARD RED: generic rest, string instantiation = " + gStr; }

	const gNum = firstOr(9, 7);
	if (gNum !== 7) { throw "GUARD RED: generic rest, number instantiation = " + gNum.toString(); }

	const gEmpty = firstOr("fallback");
	if (gEmpty !== "fallback") { throw "GUARD RED: generic rest with no trailing args = " + gEmpty; }

	// Non-primitive element type: the packed array holds references.
	const weight = totalWeight(1, new Weighted(2), new Weighted(3));
	if (weight !== 6) { throw "GUARD RED: struct element rest = " + weight.toString(); }

	console.log("restParamVarargs ok");
}

main();
