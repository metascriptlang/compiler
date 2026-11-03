import { argv } from "std/process";
import { collectCycles } from "std/runtime";

class Link { next: Link | null = null; id: int32 = 0; }

function dropRing(size: int32): int64 {
	const head = new Link();
	let tail = head;
	for (let i: int32 = 1; i < size; i++) {
		const n = new Link();
		n.id = i;
		tail.next = n;
		tail = n;
	}
	tail.next = head;
	return tail.id as int64;
}

const count: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 500000;
const size: int32 = argv.length > 2 ? argv[2].parseInt() as int32 : 500;
let sum: int64 = 0;
for (let made: int32 = 0; made < count; made += size) {
	sum += dropRing(size);
	collectCycles();
}
console.log(`collectRing ${sum}`);
