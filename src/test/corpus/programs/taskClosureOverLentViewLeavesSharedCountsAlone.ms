// @stdout: total=3000
// note: three tasks share one lent array; each builds a closure over a view of it (in the task, in a called routine, and one closure level deeper) and calls it in place. The closure env holds the view uncounted, so no task touches a count of the shared graph.
class Item { v: int32 = 0; next: Item | null = null; }

function make(): Item[] {
	const items: Item[] = [];
	for (let i = 0; i < 8; i++) { const it = new Item(); it.v = i as int32; items.push(it); }
	return items;
}

function viaCapture(items: Readonly<Item[]>): int32 {
	const best = items[3];
	const ok = (x: Readonly<Item>): boolean => x.v >= best.v;
	let n: int32 = 0;
	for (const x of items) if (ok(x)) n += 1;
	return n;
}

async function round(): Promise<int32> {
	const items = make();
	const a = spawn((): int32 => {
		const best = items[3];
		const ok = (x: Readonly<Item>): boolean => x.v >= best.v;
		let n: int32 = 0;
		for (const x of items) if (ok(x)) n += 1;
		return n;
	});
	const b = spawn((): int32 => viaCapture(items));
	const c = spawn((): int32 => {
		const best = items[3];
		const outer = (x: Readonly<Item>): boolean => {
			const inner = (): boolean => x.v >= best.v;
			return inner();
		};
		let n: int32 = 0;
		for (const x of items) if (outer(x)) n += 1;
		return n;
	});
	return await a + await b + await c;
}

let total: int32 = 0;
for (let k = 0; k < 200; k++) total += await round();
console.log(`total=${total}`);
