// @exit: 1
// @skip-js: C-only by design: the check runs when an edge is read after the DRC destroyed its target; JS frees nothing
// @stdout: kept 1, destroyed 2
// @stdout: Error: an Unowned<N> edge was read after its N was destroyed
// @ledger-slack(msRefArrayRefCell) 1
// note: an array of Unowned<T> returned from a function outlives the targets its elements point at; reading such an element stops the program instead of reading the destroyed object.
class N { id: int32; constructor(id: int32) { this.id = id; } }
let destroyed = 0;
function onDestroy(this n: N): void { destroyed++; }

function survivor(): Unowned<N>[] {
	const a = new N(7);
	const b = new N(8);
	const xs: Unowned<N>[] = [a, b];
	return xs.filter((n: N): boolean => n.id == 8);
}

const kept = survivor();
console.log("kept " + kept.length.toString() + ", destroyed " + destroyed.toString());
console.log("unreachable " + kept[0].id.toString());
