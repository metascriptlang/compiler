// Two spawns that only read one local lend it together until both awaits; the second spawn is not a
// change of what the first one reads. The local is built through a reassigned alias first, the
// shape whose second spawn was refused as "the change". Its refused neighbours: spawnLendRefuses.ms.
//
// GUARD-JS

class N { v: int32 = 1; next: N | null = null; }

function walk(root: Readonly<N>): int32 { return root.v + (root.next != null ? root.next.v : 0); }

async function throughACallee(): Promise<int32> {
	const head = new N();
	let cur = head;
	const n = new N();
	cur.next = n;
	cur = n;
	const a = spawn(() => walk(head));
	const b = spawn(() => walk(head));
	return (await a) + (await b);
}

async function fieldReadsAfterALoop(): Promise<int32> {
	const head = new N();
	let cur = head;
	for (let i = 0; i < 3; i += 1) {
		const n = new N();
		cur.next = n;
		cur = n;
	}
	const a = spawn(() => head.v);
	const b = spawn(() => head.next != null ? head.next.v : 0);
	return (await a) + (await b);
}

const r = await throughACallee() + await fieldReadsAfterALoop();
if (r == 6) console.log("GUARD-OK");
else console.log(`unexpected r=${r}`);
