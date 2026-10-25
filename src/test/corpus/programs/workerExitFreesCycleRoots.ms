// @stdout: broken self cycles 4
// @stdout: broken pair cycles 4
// @exit: 0
// @serial
// @skip-js: the cycle collector and pool workers are C backend only
// @skip-raiser
// note: a pool worker whose cycle candidates were all freed still frees its candidate buffer when the pool shuts down (old runtime: LeakSanitizer reports the msRealloc in msCellSeqGrow, under msRegisterCycle, once the worker exits; Linux only, the macOS ledger counts cells, not the buffer)

class Node {
	v: int32 = 1;
	next: Node | null = null;
}

function brokenSelfCycle(): int32 {
	const a = new Node();
	a.next = a;
	a.next = null;
	return a.v;
}

function brokenPairCycle(): int32 {
	const a = new Node();
	const b = new Node();
	a.next = b;
	b.next = a;
	a.next = null;
	return a.v + b.v - 1;
}

async function selfCycles(): Promise<int32> {
	const t1 = spawn(brokenSelfCycle);
	const t2 = spawn(brokenSelfCycle);
	const t3 = spawn(brokenSelfCycle);
	const t4 = spawn(brokenSelfCycle);
	return (await t1) + (await t2) + (await t3) + (await t4);
}

async function pairCycles(): Promise<int32> {
	const t1 = spawn(brokenPairCycle);
	const t2 = spawn(brokenPairCycle);
	const t3 = spawn(brokenPairCycle);
	const t4 = spawn(brokenPairCycle);
	return (await t1) + (await t2) + (await t3) + (await t4);
}

console.log(`broken self cycles ${await selfCycles()}`);
console.log(`broken pair cycles ${await pairCycles()}`);
