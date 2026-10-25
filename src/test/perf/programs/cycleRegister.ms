import { argv } from "std/process";

class Ring { peer: Ring | null = null; id: int32 = 0; }

function makeRings(count: int32): int64 {
	let sum: int64 = 0;
	for (let i: int32 = 0; i < count; i++) {
		const a = new Ring();
		const b = new Ring();
		a.id = i;
		a.peer = b;
		b.peer = a;
		sum += b.peer!.id;
		b.peer = null;
	}
	return sum;
}

const count: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 1000000;
console.log(`cycleRegister ${makeRings(count)}`);
