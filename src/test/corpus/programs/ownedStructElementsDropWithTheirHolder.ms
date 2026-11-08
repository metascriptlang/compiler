// @skip-js: C-only by design: onDestroy counts the DRC's destroys; JS frees nothing
// @stdout: sum 500500 nodes 1001
// @stdout: destroyed 1001
// note: a class whose children sit in an array of value structs, each holding an Owned<T> edge, is classified acyclic in a release build like an Owned<T>[] field, and every node is destroyed once when the root goes.
let destroyed = 0;
struct Slot { child: Owned<N> | null; weight: int32; }
class N {
	id: int32 = 0;
	slots: Slot[] = [];
}
function onDestroy(this n: N): void { destroyed++; }

function build(n: int32): int32 {
	const root = new N();
	let sum = 0;
	let nodes = 1;
	for (let i: int32 = 1; i <= n; i++) {
		const k = new N();
		k.id = i;
		root.slots.push({ child: k, weight: i });
	}
	for (const s of root.slots) {
		const c = s.child;
		if (c != null) {
			sum += c.id;
			nodes += 1;
		}
	}
	console.log("sum " + sum.toString() + " nodes " + nodes.toString());
	return nodes;
}

build(1000);
console.log("destroyed " + destroyed.toString());
