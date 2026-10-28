// @stdout: a2 a3 a1 a2
// note: a narrowing of `entry.items[0]` holds across a loop that does not write that element, for `for of`, `while` and an identifier index; a loop that assigns the element is the negative control (narrowElementAcrossLoopRejects guard).

enum Kind { A, B }
struct Item = match (kind: Kind) {
	Kind.A => { name: string },
	Kind.B => { n: int32 },
};
struct Entry { items: Item[]; }

function viaFor(entry: Entry): string {
	if (entry.items.length != 2 || entry.items[0].kind != Kind.A) { return "malformed"; }
	let count = 0;
	for (const item of entry.items) { count += 1; }
	return entry.items[0].name + count.toString();
}
function viaWhile(entry: Entry): string {
	if (entry.items.length != 2 || entry.items[0].kind != Kind.A) { return "malformed"; }
	let count = 0;
	while (count < 3) { count += 1; }
	return entry.items[0].name + count.toString();
}
function viaIndex(items: Item[], i: int32): string {
	if (items[i].kind != Kind.A) { return "malformed"; }
	let count = 0;
	while (count < 1) { count += 1; }
	return items[i].name + count.toString();
}
function nestedLoops(entry: Entry): string {
	if (entry.items[0].kind != Kind.A) { return "malformed"; }
	let count = 0;
	for (const item of entry.items) {
		let k = 0;
		while (k < 1) { k += 1; count += 1; }
	}
	return entry.items[0].name + count.toString();
}

const e: Entry = { items: [{ kind: Kind.A, name: "a" }, { kind: Kind.B, n: 1 }] };
console.log(viaFor(e), viaWhile(e), viaIndex(e.items, 0), nestedLoops(e));
