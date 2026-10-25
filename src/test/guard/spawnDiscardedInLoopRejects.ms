// nim-guard: a spawn result discarded inside a loop is refused like one outside it.
//
// INVARIANT (ULTRALOCK T1/T2): a bare `spawn(...)` statement leaves its task with
//   no handle, so nothing joins it and its borrowed captures outlive the lend; the
//   refusal holds in every scope, loop bodies included.
//
// WHAT IT CATCHES: the loop carve-out of E1 coming back; with it the task read a
//   parameter its caller had already released (ASan use-after-free).
//
// RED MEANS: the bare spawn in a loop compiled.
//
// GUARD-CHECK-FAIL spawn result is discarded

class Box { items: number[] = []; }

function fire(box: Box): void {
	for (let k = 0; k < 1; k += 1) {
		spawn(() => {
			let s: number = 0;
			for (const x of box.items) s += x;
			console.log(`sum ${s}`);
		});
	}
}

const shared = new Box();
shared.items.push(1);
fire(shared);
shared.items = [];
