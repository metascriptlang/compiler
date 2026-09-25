// nim-guard: a registered ORC root leaves the root buffer before its destructor runs
//
// INVARIANT (orc.nim nimDecRefIsLastDyn / nimDecRefIsLastCyclicDyn: a last decref
//   unregisters the cell before `=destroy`): a collect deferred to the end of that
//   destructor must never see the dying object as a root, or it is freed twice.
// NIM-REF AN-19 (SAME). The holder's last ref leaves through a type-erased runtime
//   container op; the varying filler count lands the deferred collect inside the
//   destructor on some iterations.
//
// RED MEANS: a runtime decref path returns "last" while the cell is still in msRoots.
//   Run /trace-nim on msDecRefIsLast / msOrcDecRefIsLast (runtime/drc.h).

class Node {
	next: Node | null = null;
	child: Node | null = null;
	id: int32 = 0;
}

function filler(i: int32): void {
	const n = new Node();
	n.next = n;
	n.id = i;
}

function mkPair(): Node {
	const c = new Node();
	const d = new Node();
	c.next = d;
	d.next = c;
	return c;
}

function heldByArray(): void {
	const holder: Node[] = [];
	const x = new Node();
	holder.push(x);
	x.child = mkPair();
	x.id = 7;
}

function heldByVec(): void {
	const holder: Vec<Node> = [];
	const x = new Node();
	holder.push(x);
	x.child = mkPair();
	x.id = 7;
}

function sweep(useVec: boolean): void {
	for (let r: int32 = 0; r < 5000; r++) {
		for (let i: int32 = 0; i < (r * 7 + r / 13) % 11; i++) {
			filler(i);
		}
		if (useVec) heldByVec();
		else heldByArray();
	}
}

sweep(false);
sweep(true);
console.log("GUARD-OK");
