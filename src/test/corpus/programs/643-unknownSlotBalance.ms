// @stdout: unknown-slot field=2000 elems=3 iface=2000 plain=plain

class Node {
	name: string;
	constructor(name: string) { this.name = name; }
}

class Holder {
	slot: unknown | null = null;
	bare: unknown;
	constructor(b: unknown) { this.bare = b; }
}

interface Rec { slot: unknown | null; }

function fieldChurn(): int32 {
	let seen = 0 as int32;
	for (let i = 0; i < 2000; i += 1) {
		const m = new Node("f");
		const h = new Holder(m);
		h.slot = m;
		h.slot = null;
		h.slot = m;
		h.bare = m;
		if (h.slot !== null) seen += 1;
	}
	return seen;
}

function elemChurn(): int32 {
	let last = 0 as int32;
	for (let i = 0; i < 2000; i += 1) {
		const m = new Node("e");
		const xs: (unknown | null)[] = [];
		xs.push(m);
		xs.push(null);
		xs.push(m);
		xs[1] = m;
		last = xs.length as int32;
	}
	return last;
}

function ifaceChurn(): int32 {
	let seen = 0 as int32;
	for (let i = 0; i < 2000; i += 1) {
		const m = new Node("i");
		const r: Rec = { slot: m };
		r.slot = null;
		r.slot = m;
		if (r.slot !== null) seen += 1;
	}
	return seen;
}

function main(): void {
	const plain = new Node("plain");
	const a = fieldChurn();
	const b = elemChurn();
	const c = ifaceChurn();
	console.log(`unknown-slot field=${a} elems=${b} iface=${c} plain=${plain.name}`);
}
main();
