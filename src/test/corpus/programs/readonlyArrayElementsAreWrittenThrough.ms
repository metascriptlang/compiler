// @stdout: 3 2 1 a,b 4 7 3
// note: readonly T[] keeps its elements T, as in TypeScript: a field written through an element, an element handed to a mutable parameter, an inner array pushed, a slice that is a new writable array.
class Item { n: int32; constructor(n: int32) { this.n = n; } }
function bump(i: Item): void { i.n += 1; }
function touch(xs: readonly Item[]): void { xs[0].n += 1; bump(xs[1]); for (const x of xs) x.n += 0; }
function grow(rows: readonly string[][]): void { rows[0].push("b"); }
function first<T>(xs: ReadonlyArray<T>): T { return xs[0]; }
function copyOut(xs: readonly Item[]): Item[] { const w = xs.slice(0); w.push(new Item(7)); return w; }
const items: Item[] = [new Item(2), new Item(1), new Item(1)];
touch(items);
const rows: string[][] = [["a"]];
grow(rows);
const w = copyOut(items);
console.log(`${items[0].n} ${items[1].n} ${items[2].n} ${rows[0].join(",")} ${w.length} ${w[3].n} ${first(items).n}`);
