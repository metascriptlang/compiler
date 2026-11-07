// @stdout: for== false true|for!= true false|deep false false true|while false true|found 1 2 0
// @exit: 0

// A local that walks `Unowned` back edges compares by identity on every backend. The loop's update assigns the
// back edge to the local, and the type flow gives it at the loop head must stay the local's reference type: a
// type that keeps `Unowned` made the head a two-arm union, and C compared the local's pointer as a tagged union.

class N { id: int32 = 0; parent: Unowned<N> | null = null; }

function node(id: int32, parent: N | null): N {
	const n = new N();
	n.id = id;
	n.parent = parent;
	return n;
}

function eqWalk(p: N, c: N): string {
	let out = "";
	for (let q: N | null = p; q != null; q = q.parent) out = out + (out == "" ? "" : " ") + (q == c ? "true" : "false");
	return out;
}

function neWalk(p: N, c: N): string {
	let out = "";
	for (let q: N | null = p; q != null; q = q.parent) out = out + (out == "" ? "" : " ") + (q != c ? "true" : "false");
	return out;
}

function whileWalk(p: N, c: N): string {
	let out = "";
	let q: N | null = p;
	while (q != null) {
		out = out + (out == "" ? "" : " ") + (q == c ? "true" : "false");
		q = q.parent;
	}
	return out;
}

function depthOf(p: N, c: N): int32 {
	let depth: int32 = 0;
	for (let q: N | null = p; q != null; q = q.parent) {
		if (q == c) return depth;
		depth += 1;
	}
	return -1;
}

const root = node(1, null);
const mid = node(2, root);
const leaf = node(3, mid);
console.log("for== " + eqWalk(mid, root) + "|for!= " + neWalk(mid, root) + "|deep " + eqWalk(leaf, root) + "|while " + whileWalk(mid, root) + "|found " + depthOf(leaf, mid).toString() + " " + depthOf(leaf, root).toString() + " " + depthOf(leaf, leaf).toString());
