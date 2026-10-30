// @stdout: 0 0 0 0|1 1
// note: a `Cell[]` / `Entry[]` cell gets its destroy op in the module that instantiates a function over
// the holder (generic.ms, plain.ms) and its trace op where the array type first appears (main.ms).
// The C build threw "has its destroy op in <one module> and its trace op in <another>"; the holder is
// a Vec field and a Map of Vec, reached from a generic and from a non-generic function.
import { Cell, Entry, Scene } from "./model";
import { touch } from "./generic";
import { touchCells, touchEntries } from "./plain";

const s: Scene = { cells: [], entries: new Map() };
const cells: Cell[] = [];
const entries: Entry[] = [];
const out: string[] = [`${touch(s)} ${touchCells(s)} ${touchEntries(s)} ${cells.length + entries.length}`];
cells.push({ texture: null });
entries.push({ texture: null });
out.push(`${cells.length} ${entries.length}`);
console.log(out.join("|"));
