// @serial
// @stdout: boundaries 4 4 4 4 14 5
// note: a generic routine's instance is a different symbol in each module that calls it, so a routine that stores its parameter and is generic stays borrowed; a routine that builds a closure over its parameter stays borrowed; each caller below passes an element it still owns.

import { Box, Item, make, keepOne, keepBoxed } from "./lib";
import { fillNames, fillItems, fillBox } from "./other";

function holdThenStore(b: Box, it: Item, n: int32): () => int32 {
	b.items.push(it);
	return (): int32 => it.id + n;
}

async function sumAcross(items: Item[], extra: int32): Promise<int32> {
	let total: int32 = 0;
	const jobs: Promise<int32>[] = [];
	for (let i = 0; i < items.length; i++) {
		const it = items[i];
		jobs.push(spawn((): int32 => it.id + extra));
	}
	for (const j of jobs) total += await j;
	return total;
}

const names = ["a" + "b".repeat(100), "c" + "d".repeat(100)];
const seen = new HashSet<string>();
fillNames(seen, names);
for (let i = 0; i < names.length; i++) seen.add(names[i] + "!");
const items = [make(1), make(2)];
const into: Item[] = [];
fillItems(into, items);
for (let i = 0; i < items.length; i++) keepOne(into, items[i]);
const box = new Box();
fillBox(box, items);
for (let i = 0; i < items.length; i++) keepBoxed(box, items[i]);
const f = holdThenStore(box, make(7), 3);
const spawned = await sumAcross(items, 1);
console.log(`boundaries ${seen.size} ${into.length} ${box.items.length - 1} ${items[0].id + items[1].id + 1} ${f() + 4} ${spawned}`);
