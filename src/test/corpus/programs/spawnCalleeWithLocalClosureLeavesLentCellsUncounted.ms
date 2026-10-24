// @stdout: total=156000

class Item { v: int32 = 0; next: Item | null = null; }

function countUp(items: Readonly<Item[]>): int32 {
	const ok = (x: Readonly<Item>): boolean => x.v >= 2;
	let n: int32 = 0;
	for (const x of items) if (ok(x)) n += 1;
	return n;
}

function countFrom(head: Readonly<Item>): int32 {
	const ok = (x: Readonly<Item>): boolean => x.v >= 2;
	let n: int32 = 0;
	let cur: Readonly<Item> | null = head;
	while (cur != null) {
		if (ok(cur)) n += 1;
		cur = cur.next;
	}
	return n;
}

function countBoth(items: Readonly<Item[]>): int32 {
	return countFrom(items[0]) + countUp(items) + countFrom(items[1]);
}

async function round(): Promise<int32> {
	const items: Item[] = [];
	for (let i = 0; i < 8; i++) {
		const it = new Item();
		it.v = i as int32;
		if (i > 0) items[i - 1].next = it;
		items.push(it);
	}
	const a = spawn(() => countBoth(items));
	const b = spawn(() => countBoth(items));
	const c = spawn(() => countBoth(items));
	const d = spawn(() => countBoth(items));
	const e = spawn(() => countUp(items));
	return await a + await b + await c + await d + await e;
}

let total: int32 = 0;
for (let k = 0; k < 2000; k++) total += await round();
console.log(`total=${total}`);
