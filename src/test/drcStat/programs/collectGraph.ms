import { argv } from "std/process";

class Cell { next: Cell | null = null; back: Cell | null = null; id: int32 = 0; }

function makeGarbage(count: int32): int64 {
	let sum: int64 = 0;
	for (let i: int32 = 0; i < count; i++) {
		const a = new Cell();
		const b = new Cell();
		a.next = b;
		b.back = a;
		a.id = i;
		sum += a.id;
	}
	return sum;
}

const count: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 500000;
console.log(`collectGraph ${makeGarbage(count)}`);
