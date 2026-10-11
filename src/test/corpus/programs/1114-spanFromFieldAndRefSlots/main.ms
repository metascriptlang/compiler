// @stdout: 7 7 9|1 5|6 9 11|5 1|9 1 2 50
// note: a Span built from a field reached through a `ref` parameter is dereferenced once, a
// Span over interface elements carries the element-slot pointer type, and the source of a Span
// is evaluated once, under a ternary arm and in a loop condition too: a call inside it becomes a
// temp and each read copies the remaining pure path (reference: openArrayLoc). One source node
// used to hang under both `data` and `len`, so a pass rewriting it in place dereferenced twice.
@passC("-Werror=incompatible-pointer-types");

struct Data { items: Vec<int32>; more: Vec<int32>; }
function first(items: Readonly<Span<int32>>): int32 { return items[0]; }
function total(items: Readonly<Span<int32>>): int32 { let t = 0; for (const x of items) t += x; return t; }
function run(ref data: Data): int32 { return first(data.items); }
function runSlice(ref data: Data): int32 { return first(data.items[0..1]); }
function runMut(ref data: Data): int32 { return total(data.more); }

interface Item { z: int32; }
function lowest(items: Readonly<Span<Item>>): int32 {
	let low: int32 = items[0].z;
	for (const item of items) { if (item.z < low) low = item.z; }
	return low;
}
struct Shelf { items: Item[]; }

let calls: int32 = 0;
function make(): Vec<int32> { calls += 1; return [1, 2, 3]; }
struct Bag { items: Vec<int32>; }
let bags: Bag[] = [{ items: [4, 5] }];
function at(): int32 { calls += 10; return 0; }
let starts: int32 = 0;
function start(): int32 { starts += 1; return 1; }

const out: string[] = [];
let data: Data = { items: [7], more: [4, 5] };
out.push(`${run(data)} ${runSlice(data)} ${runMut(data)}`);
const items: Item[] = [{ z: 3 }, { z: 1 }, { z: 2 }];
const shelf: Shelf = { items: [{ z: 5 }, { z: 8 }] };
out.push(`${lowest(items)} ${lowest(shelf.items)}`);
out.push(`${total(make())} ${total(bags[at()].items)} ${calls}`);
let v: Vec<int32> = [1, 2, 3, 4];
out.push(`${total(v[start()..3])} ${starts}`);
let probes: int32 = 0;
function slot(i: int32): int32 { probes += 10; return i; }
function pick(c: boolean): int32 { return c ? total(bags[slot(0)].items) : total(more[slot(0)].items); }
let more: Bag[] = [{ items: [1] }];
let n = 0;
while (total(bags[slot(0)].items) + n < 11) { n += 1; }
out.push(`${pick(true)} ${pick(false)} ${n} ${probes}`);
console.log(out.join("|"));
