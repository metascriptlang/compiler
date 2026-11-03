import { argv } from "std/process";

class Item { id: int32 = 0; }

function grow(count: int32, rounds: int32): int64 {
	let sum: int64 = 0;
	for (let r: int32 = 0; r < rounds; r++) {
		const items: Item[] = [];
		for (let i: int32 = 0; i < count; i++) {
			const it = new Item();
			it.id = i;
			items.push(it);
		}
		while (items.length > count / 2) {
			sum += items.pop()!.id;
		}
	}
	return sum;
}

const count: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 1000;
console.log(`arrayOfRefs ${grow(count, 400)}`);
