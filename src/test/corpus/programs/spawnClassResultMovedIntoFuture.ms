// @stdout: node 2
// @stdout: chain 3
// @stdout: closure 5
// @stdout: list 2 3
// note: a class instance a spawned task returns moves into its future, for one instance, a chain built in a loop, a closure that holds a chain, and an array of instances.

class Node {
	next: Node | null = null;
	payload: string;
	constructor(payload: string) { this.payload = payload; }
}

function makeChain(n: int32): Node {
	const head = new Node("n0");
	let prev = head;
	for (let i = 1; i < n; i += 1) {
		const node = new Node(`n${i}`);
		prev.next = node;
		prev = node;
	}
	return head;
}

function lengthOf(head: Node): int32 {
	let k = 0;
	let at: Node | null = head;
	while (at != null) {
		k += 1;
		at = at.next;
	}
	return k;
}

function reader(n: int32): Sendable<() => int32> {
	const head = makeChain(n);
	return (): int32 => n + head.payload.length;
}

async function main(): Promise<void> {
	const one = await spawn((): Node => new Node("n0"));
	console.log(`node ${one.payload.length}`);
	const chain = await spawn((): Node => makeChain(3));
	console.log(`chain ${lengthOf(chain)}`);
	const read = await spawn(() => reader(3));
	console.log(`closure ${read()}`);
	const list = await spawn((): Node[] => [makeChain(2), new Node("x")]);
	console.log(`list ${list.length} ${lengthOf(list[0]) + lengthOf(list[1])}`);
}

await main();
