// @stdout: total=46000
// note: worker tasks run array readers over arrays the spawning task owns; a callback that writes nothing the reader holds runs a reader body that counts no element, so no task writes a refcount it does not own.
class Item { v: int32 = 0; next: Item | null = null; }

struct Slot { item: Item; w: int32; }

function countIf<T>(this arr: Readonly<T[]>, fn: (x: Readonly<T>) => boolean): int32 {
	let n: int32 = 0;
	for (let i = 0; i < arr.length; i++) if (fn(arr[i])) n += 1;
	return n;
}

function viaFindIndex(items: Readonly<Item[]>): int32 {
	return items.findIndex((y: Readonly<Item>): boolean => y.v == 2) as int32;
}

function viaFindLastIndex(items: Readonly<Item[]>): int32 {
	return items.findLastIndex((y: Readonly<Item>): boolean => y.v == 3) as int32;
}

function viaSome(items: Readonly<Item[]>): int32 {
	return items.some((y: Readonly<Item>): boolean => y.v == 4) ? 1 : 0;
}

function viaMap(items: Readonly<Item[]>): int32 {
	return items.map((y: Readonly<Item>): int32 => y.v).length as int32;
}

function viaUserReader(items: Readonly<Item[]>): int32 {
	return items.countIf((y: Readonly<Item>): boolean => y.v > 4);
}

function viaStructs(slots: Readonly<Slot[]>): int32 {
	return slots.findIndex((s: Readonly<Slot>): boolean => s.item.v == 6) as int32;
}

async function round(): Promise<int32> {
	const items: Item[] = [];
	const slots: Slot[] = [];
	for (let i = 0; i < 8; i++) { const it = new Item(); it.v = i as int32; items.push(it); slots.push({ item: it, w: i as int32 }); }
	const a = spawn(() => viaFindIndex(items));
	const b = spawn(() => viaFindLastIndex(items));
	const c = spawn(() => viaSome(items));
	const d = spawn(() => viaMap(items));
	const e = spawn(() => viaUserReader(items));
	const g = spawn(() => viaStructs(slots));
	return await a + await b + await c + await d + await e + await g;
}

let total: int32 = 0;
for (let k = 0; k < 2000; k++) total += await round();
console.log(`total=${total}`);
