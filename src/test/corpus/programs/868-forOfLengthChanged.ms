// @stdout: pop raised after 1, | push raised after 1, | last raised after 1,2,3, | continue raised after 1, | break finished 1, | rebind finished 1,2,3, | same-length rebind finished 1,2,3, | field raised after 1, | vec raised after 1,
// @xfail(raiser): assigning a new array to the iterated variable writes into the array the loop holds (CG-40)
// note: for-of over an array checks the length after each element and raises when the body changed it, as Nim's items does for seq. The loop used to fix the length once and then read past the end (C: index error, JS: undefined) or skip the pushed elements. Rebinding the iterated T[] variable leaves the loop on the array it started, as TypeScript's for-of holds it (NIM-REF TR-26); the loop used to read through the rebinding and raise, or mix the two arrays when their lengths matched (1,8,9).

class Bag { items: int32[]; constructor() { this.items = [1, 2, 3]; } }

function pop(): string {
	const arr: int32[] = [1, 2, 3, 4];
	let seen = "";
	try {
		for (const x of arr) { seen = seen + String(x) + ","; arr.pop(); }
	} catch (e) {
		return "pop raised after " + seen;
	}
	return "pop finished " + seen;
}

function push(): string {
	const arr: int32[] = [1, 2, 3];
	let seen = "";
	try {
		for (const x of arr) { seen = seen + String(x) + ","; arr.push(x * 10); }
	} catch (e) {
		return "push raised after " + seen;
	}
	return "push finished " + seen;
}

function last(): string {
	const arr: int32[] = [1, 2, 3];
	let seen = "";
	try {
		for (const x of arr) { seen = seen + String(x) + ","; if (x == 3) arr.push(4); }
	} catch (e) {
		return "last raised after " + seen;
	}
	return "last finished " + seen;
}

function viaContinue(): string {
	const arr: int32[] = [1, 2, 3];
	let seen = "";
	try {
		for (const x of arr) {
			seen = seen + String(x) + ",";
			if (x == 1) { arr.push(9); continue; }
		}
	} catch (e) {
		return "continue raised after " + seen;
	}
	return "continue finished " + seen;
}

function viaBreak(): string {
	const arr: int32[] = [1, 2, 3];
	let seen = "";
	try {
		for (const x of arr) { seen = seen + String(x) + ","; arr.push(9); break; }
	} catch (e) {
		return "break raised after " + seen;
	}
	return "break finished " + seen;
}

function rebind(): string {
	let arr: int32[] = [1, 2, 3];
	let seen = "";
	try {
		for (const x of arr) { seen = seen + String(x) + ","; arr = [7, 8, 9, 10]; }
	} catch (e) {
		return "rebind raised after " + seen;
	}
	return "rebind finished " + seen;
}

function sameLengthRebind(): string {
	let arr: int32[] = [1, 2, 3];
	let seen = "";
	try {
		for (const x of arr) { seen = seen + String(x) + ","; arr = [7, 8, 9]; }
	} catch (e) {
		return "same-length rebind raised after " + seen;
	}
	return "same-length rebind finished " + seen;
}

function field(): string {
	const b = new Bag();
	let seen = "";
	try {
		for (const x of b.items) { seen = seen + String(x) + ","; b.items.pop(); }
	} catch (e) {
		return "field raised after " + seen;
	}
	return "field finished " + seen;
}

function vecPop(): string {
	const v: Vec<int32> = [1, 2, 3];
	let seen = "";
	try {
		for (const x of v) { seen = seen + String(x) + ","; v.pop(); }
	} catch (e) {
		return "vec raised after " + seen;
	}
	return "vec finished " + seen;
}

console.log([pop(), push(), last(), viaContinue(), viaBreak(), rebind(), sameLengthRebind(), field(), vecPop()].join(" | "));
