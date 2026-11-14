// @exit: 1
// @stdout: len 3
// @stdout: Error: unreachable: the length of the array changed while iterating over it
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a for-of inside onDestroy over an array the hook grows stops the program, because a hook cannot throw and a catch around the release cannot keep it going (old compiler: the length check threw out of the hook, the error was lost and the program printed "returned")

class Bag { items: int32[] = [1, 2, 3]; }
function onDestroy(this b: Bag): void {
	let sum = 0;
	for (const x of b.items) {
		sum = sum + x;
		if (x == 1) b.items.push(9);
	}
	console.log(`sum ${sum}`);
}

function scope(): void {
	const b = new Bag();
	console.log(`len ${b.items.length}`);
}

try {
	scope();
	console.log("returned");
} catch (e) {
	console.log("caught a hook error");
}
console.log("end");
