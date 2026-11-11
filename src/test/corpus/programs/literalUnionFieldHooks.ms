// @stdout: a|b|2|ab|b|1|4
// note: a field typed as a union of string literals is a string at runtime and carries string hooks in every struct, whether or not the struct has another string: a heap string stored through a cast is released, copied and moved with its owner. The pin is a lone union field, a struct in a struct, a sized array of the struct, and an array of the struct.
type Fmt = "a" | "b";
struct Slot { k: Fmt; n: int32; }
struct Outer { slot: Slot; tag: int32; }

function heap(first: boolean): Fmt {
	const base = first ? "a" : "b";
	const v: string = base.repeat(1) + "";
	return v as Fmt;
}

function dup(s: Slot): Slot { const t = s; return t; }

function run(): string {
	const s: Slot = { k: heap(true), n: 1 };
	const t = dup(s);
	const o: Outer = { slot: { k: heap(false), n: 2 }, tag: 3 };
	const o2 = o;
	const grid: Slot[2] = [{ k: heap(true), n: 5 }, { k: heap(false), n: 6 }];
	const g2 = grid;
	const list: Slot[] = [dup(s), dup(o.slot)];
	return `${t.k}|${o2.slot.k}|${o.slot.n}|${g2[0].k}${g2[1].k}|${list[1].k}|${list[0].n}|${list.length + grid.length}`;
}
console.log(run());
