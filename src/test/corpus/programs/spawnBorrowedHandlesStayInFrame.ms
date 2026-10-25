// @stdout: literal total=29975
// @stdout: pushed total=29975
// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native exit join of borrowing handles
// note: handles of tasks that borrow a frame's Node stay in that frame, in an array literal and in a pushed local array, and are awaited there; each total is 5 * sum(i % 7) over 2000 rounds. The shape that returned the array to its caller (`two(n)` returning `[spawn(...), spawn(...)]`) is refused since ULTRALOCK T1 keeps a borrowing handle in its scope; before that refusal it read the results after the callee's exit join and printed garbage (436, 183) instead of 29975.

class Node { v: int32; constructor(v: int32) { this.v = v; } }

function leaf(n: Readonly<Node>): int32 { return n.v; }

function literalRound(i: int32): int32 {
	const n = new Node(i % 7);
	const bs = [spawn((): int32 => leaf(n) * 2), spawn((): int32 => leaf(n) * 3)];
	return await bs[0] + await bs[1];
}

function pushedRound(i: int32): int32 {
	const n = new Node(i % 7);
	const bs: Promise<int32>[] = [];
	bs.push(spawn((): int32 => leaf(n) * 2));
	bs.push(spawn((): int32 => leaf(n) * 3));
	let sum: int32 = 0;
	for (const r of await Promise.all(bs)) sum += r;
	return sum;
}

let literal: int32 = 0;
let pushed: int32 = 0;
for (let i: int32 = 0; i < 2000; i++) {
	literal += literalRound(i);
	pushed += pushedRound(i);
}
console.log(`literal total=${literal}`);
console.log(`pushed total=${pushed}`);
