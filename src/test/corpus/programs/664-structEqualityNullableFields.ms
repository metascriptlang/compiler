// @xfail(raiser): struct == compares by reference on raiser (card 2026-09-29-raiser-struct-equality-by-reference)
// @stdout: prim=true,false,true,false struct=true,false,false,true reset=true
// note: `==` on a struct with a `T | null` field: two absent fields are equal, an absent and a present one are not, two present ones compare their payloads (a primitive, and a struct compared field by field). A field set back to null equals one that never held a value. Same output on every backend.

struct Cell { a: int32; s: string; }

struct Slot {
	id: int32;
	n: int32 | null;
	cell: Cell | null;
}

function main(): void {
	const a: Slot = { id: 1, n: 5, cell: { a: 2, s: "x" } };
	const b: Slot = { id: 1, n: 5, cell: { a: 2, s: "x" } };
	const c: Slot = { id: 1, n: null, cell: { a: 2, s: "x" } };
	const d: Slot = { id: 1, n: null, cell: { a: 2, s: "x" } };
	const e: Slot = { id: 1, n: 6, cell: { a: 2, s: "x" } };
	const f: Slot = { id: 1, n: 5, cell: { a: 2, s: "y" } };
	const g: Slot = { id: 1, n: 5, cell: null };
	const k: Slot = { id: 1, n: 5, cell: null };
	let m: Slot = { id: 1, n: 5, cell: { a: 7, s: "z" + "z" } };
	m.cell = null;
	console.log(`prim=${a == b},${a == c},${c == d},${a == e}`
		+ ` struct=${a == b},${a == f},${a == g},${g == k} reset=${m == g}`);
}

main();
