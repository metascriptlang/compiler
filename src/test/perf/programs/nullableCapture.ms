import { argv } from "std/process";

class Item { value: int32 = 7; next: Item | null = null; }

function read(best: Item | null): int32 {
	const get = (): int32 => best != null ? best.value : 0;
	return get();
}

function run(count: int32): int64 {
	const item = new Item();
	let sum: int64 = 0;
	for (let i: int32 = 0; i < count; i++) {
		sum += read(item);
		sum += read(null);
	}
	return sum;
}

const count: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 200000;
console.log(`nullableCapture ${run(count)}`);
