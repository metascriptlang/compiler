// @stdout: 3 3|2 of 3 owned
// note: a boxed `Cell[]` / `Slot[]` cell takes its destroy op from the generic `count<Ref>`
// instance in walk.ms, which reaches `Vec<Vec<Cell>>` and `Vec<Vec<Slot>>` first, and its trace
// op from the module where the cell type first appears: this one for `Cell[]` (the literal),
// cells.ms for `Slot[]` (the parameter of `owned`). The C build threw "has its destroy op in
// walk.ms and its trace op in main.ms"; the cell's TypeInfo now references each op where it lives.
import { Cell, Owner, Ref, size, owned } from "./cells";

const one: Cell = { owner: null };
const three: Cell[] = [one, one, one];
const r: Ref = { scene: { rows: [], slots: [] }, i: 2 };
const out: string[] = [`${size(r)} ${three.length}`];

const o: Owner = { hook: null };
out.push(`${owned([{ owner: o }, { owner: null }, { owner: o }])} of 3 owned`);
console.log(out.join("|"));
