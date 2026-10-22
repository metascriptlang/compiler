// @xfail(raiser): raiser runtime error: Unknown host function: msSpawn
// @serial
// @stdout: witness 0
// @stdout: spawned 1
// note: a cyclic spawn result nobody awaits is destroyed whole on the awaiting thread (old compiler: the SAN ledger shows Node alloc=2 destroy=1, because the child kept a stale root index from the worker's root set and the collector skipped it). `witness` destroys one Node, so the ledger row has a destroy and the SAN lane checks its balance.

class Node { next: Node | null = null; kids: Node[] = []; v: int32 = 0; }

function mk(): Node {
	const p = new Node();
	const c = new Node();
	p.kids.push(c);
	c.next = p;
	p.next = p;
	return p;
}

function witness(): void {
	const w = new Node();
	console.log(`witness ${w.v}`);
}

witness();
const hs: Promise<Node>[] = [spawn(() => mk())];
console.log(`spawned ${hs.length}`);
