// nim-guard: a spawn result discarded in a nested while loop is refused.
//
// INVARIANT (ULTRALOCK T1/T2): the refusal of a discarded spawn result does not
//   depend on loop kind or depth; an async routine is no exception.
//
// WHAT IT CATCHES: a loop carve-out that only the outer `for` lost.
//
// RED MEANS: the bare spawn in the inner loop compiled.
//
// GUARD-CHECK-FAIL spawn result is discarded

class Box { items: number[] = []; }

async function fire(box: Box): Promise<void> {
	for (let k = 0; k < 2; k += 1) {
		let j = 0;
		while (j < 2) {
			spawn(() => {
				let s: number = 0;
				for (const x of box.items) s += x;
				return s;
			});
			j += 1;
		}
	}
}

const shared = new Box();
shared.items.push(1);
await fire(shared);
shared.items = [];
