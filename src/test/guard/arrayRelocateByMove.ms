// nim-guard: splice, shift, reverse and sort relocate array elements by move
//
// INVARIANT: relocating a seq element is a move, so no hook runs and no count
//   changes (system.nim delete/insert movingCopy, algorithm.nim reverse swap and
//   merge `<-`). Every value stays in exactly one slot, also when the
//   comparator raises halfway through a merge.
//
// WHAT IT PROTECTS: the ledger balance of a cyclic class and a string-owning
//   struct through every generic relocation; the emitted C of these bodies is
//   pinned by run.ms arrayRelocatesByMove on this same file.
//
// RED MEANS a relocation copied, dropped or duplicated an element — run
//   /trace-nim on std/core/array splice, shift, reverse and mergeRuns.
// GUARD-BALANCE TOTAL
// GUARD-JS

class Node {
	name: string;
	next: Node | null = null;
	constructor(name: string) { this.name = name; }
}

struct Cell { label: string; rank: int32; }

function nodeNames(xs: Node[]): string {
	return xs.map((x: Node): string => x.name).join("");
}

function cellNames(xs: Cell[]): string {
	return xs.map((x: Cell): string => x.label).join("");
}

function nodes(): string {
	const xs: Node[] = [];
	for (let i = 0; i < 8; i += 1) xs.push(new Node(String.fromCharCode(104 - i)));
	xs[0].next = xs[1];
	xs[1].next = xs[0];
	xs.splice(1, 2);
	xs.splice(-1, 1);
	xs.reverse();
	const first = xs.shift();
	xs.sort((a: Node, b: Node): number => a.name < b.name ? -1 : 1);
	return first.name + nodeNames(xs);
}

function cells(): string {
	const xs: Cell[] = [];
	for (let i: int32 = 0; i < 8; i += 1) xs.push({ label: String.fromCharCode(104 - i).repeat(2), rank: 8 - i });
	xs.splice(1, 2);
	xs.splice(-1, 1);
	xs.reverse();
	const first = xs.shift();
	xs.sort((a: Cell, b: Cell): number => a.rank - b.rank);
	return first.label + cellNames(xs);
}

function raisingSortKeepsEveryElement(): int32 {
	let intact: int32 = 0;
	for (let stop = 1; stop < 40; stop += 1) {
		const xs: Node[] = [];
		for (let i = 0; i < 12; i += 1) xs.push(new Node(String.fromCharCode(108 - i)));
		let calls = 0;
		try {
			xs.sort((a: Node, b: Node): number => {
				calls += 1;
				if (calls == stop) throw new Error("stop");
				return a.name < b.name ? -1 : 1;
			});
		} catch (e) {
		}
		const names = xs.map((x: Node): string => x.name);
		names.sort();
		if (names.join("") == "abcdefghijkl") intact += 1;
	}
	return intact;
}

const got = `${nodes()} ${cells()} ${raisingSortKeepsEveryElement()}`;
console.log(got);
if (got != "bcdeh bbccddeehh 39") process.exit(1);
console.log("GUARD-OK");
