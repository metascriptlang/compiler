// A union slot holds a reference member as its pointer: widening shares the cell,
// projecting hands back the same cell, and every carrier (local, param, field, array
// element, named alias) owns exactly one share. Nim: case-object fields keep their
// own type desc, tyRef → `T*` (ccgtypes.nim genRecordFieldsAux / getTypeDescAux);
// a conversion on an assignment's right sinks (injectdestructors.nim moveOrCopy).
// NIM-REF CG-38, AN-26. RED MEANS a slot inlined or re-boxed the pointee, or a
// widen/projection copied twice — run /trace-nim on Cell.
// GUARD-BALANCE Cell
// GUARD-BALANCE Other
// GUARD-JS

interface Cell { v: int32; s: string }
interface Other { w: int32 }
type Named = Cell | Other;
class Holder { data: Cell | Other = { w: 0 }; }

function mk(i: int32): Cell | Other {
	if (i % 2 == 0) return { v: i, s: "c" + i.toString() } as Cell;
	return { w: i } as Other;
}

function readV(u: Cell | Other): int32 { return (u as Cell).v; }

function project(u: Cell | Other): Cell { return u as Cell; }

function main(): void {
	const c: Cell = { v: 1, s: "one" };
	let u: Cell | Other = c;
	const alias = u;
	(alias as Cell).v = 2;
	const seen = project(u);
	seen.v = seen.v + 1;
	u = { w: 7 } as Other;
	u = c;

	const named: Named = { w: 9 };
	const namedCell: Named = c;

	const h = new Holder();
	h.data = c;
	h.data = mk(4);
	h.data = mk(3);

	const arr: (Cell | Other)[] = [];
	for (let i = 0; i < 6; i += 1) arr.push(mk(i));
	arr.push(c);
	let sum = 0;
	for (let i = 0; i < 6; i += 1) {
		if (i % 2 == 0) { sum += (arr[i] as Cell).v; } else { sum += (arr[i] as Other).w; }
	}

	console.log(c.v, readV(u), readV(namedCell), (named as Other).w, (h.data as Other).w, sum, (arr[6] as Cell).s);
}
main();
console.log("GUARD-OK");
