// @stdout: param 36 | let 36 | forvar 22 | items 9 | reassigned a,b,c;x,y | closure x,y;p | shadow 9

class Item { tag: int32 = 0; constructor(tag: int32) { this.tag = tag; } }

function viaParam(a: string[], rounds: int32): int32 {
	let n: int32 = 0;
	for (let k = 0; k < rounds; k++) { for (const t of a) n += t.length as int32; }
	return n;
}

function viaLet(src: string[], rounds: int32): int32 {
	let a = src;
	let n: int32 = 0;
	for (let k = 0; k < rounds; k++) { for (const t of a) n += t.length as int32; }
	return n;
}

function viaForVar(rows: string[][]): int32 {
	let n: int32 = 0;
	for (const row of rows) { for (const t of row) n += t.length as int32; }
	return n;
}

function viaItems(a: Item[], rounds: int32): int32 {
	let n: int32 = 0;
	for (let k = 0; k < rounds; k++) { for (const t of a) n += t.tag; }
	return n;
}

function reassigned(a: string[], b: string[]): string {
	let seen = "";
	for (let k = 0; k < 2; k++) {
		for (const t of a) { seen += t + ","; a = b; }
		seen = seen.slice(0, seen.length - 1) + ";";
	}
	return seen.slice(0, seen.length - 1);
}

function closure(a: string[], b: string[]): string {
	let seen = "";
	const swap = (): void => { a = b; };
	for (let k = 0; k < 2; k++) {
		for (const t of a) { seen += t + ","; swap(); }
		seen = seen.slice(0, seen.length - 1) + ";";
	}
	return seen.slice(0, seen.length - 1);
}

function shadow(a: string[]): int32 {
	let n: int32 = 0;
	for (const t of a) {
		const a2 = [t, t];
		for (const u of a2) n += u.length as int32;
	}
	return n;
}

console.log(
	`param ${viaParam(["ab", "cde", "f"], 6)} | let ${viaLet(["ab", "cde", "f"], 6)} | forvar ${viaForVar([["a", "bb"], ["ccc", "dddd"], ["eeeee", "ffffff", "g"]])}`
	+ ` | items ${viaItems([new Item(1), new Item(2)], 3)} | reassigned ${reassigned(["a", "b", "c"], ["x", "y"])}`
	+ ` | closure ${closure(["x", "y"], ["p"])} | shadow ${shadow(["ab", "c"]) + 3}`
);
