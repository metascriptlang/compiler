// note: a path moved out of a holder the routine created, with no default to leave behind, is dropped with the holder when the holder is not read again; each moved value lives on in its taker and each holder dies once (a local redeclared on every loop turn starts unlocked).
// @stdout: element b
// @stdout: field 7
// @stdout: struct field 7
// @stdout: array element 7
// @stdout: loop 14
interface Leaf { v: string; }
class Cell { v: int32 = 7; }
struct Wrap { leaf: Cell; }
class Holder { leaf: Cell = new Cell(); wrap: Wrap = { leaf: new Cell() }; }

function element(): string {
	const arr: Leaf[] = [{ v: "a" }, { v: "b" }];
	const out: Leaf[] = [];
	out.push(move arr[1]);
	return out[0].v;
}
function field(): int32 { const h = new Holder(); const t = move h.leaf; return t.v; }
function structField(): int32 { const h = new Holder(); const w = move h.wrap; return w.leaf.v; }
function arrayElement(): int32 { const xs: Cell[] = [new Cell()]; const t = move xs[0]; return t.v; }
function loop(): int32 {
	let s = 0;
	for (let i = 0; i < 2; i++) { let w: Wrap = { leaf: new Cell() }; const t = move w.leaf; s += t.v; }
	return s;
}
console.log("element", element());
console.log("field", field());
console.log("struct field", structField());
console.log("array element", arrayElement());
console.log("loop", loop());
