// Spawned workers lent one tree read its Unowned up-edges without a count on the shared parents
//
// INVARIANT (ULTRALOCK V2, V5; NIM-REF AN-41): a graph lent to spawned workers is read through its
//   Unowned<T> edges as plain loads: a null test, a field read, a lent argument and a cursor local take
//   no rc op on the target, so no worker writes a header another worker reads.
//
// WHAT IT CATCHES: an Unowned read lowered to a counted load: eight workers incref and decref the same
//   parents without atomics, TSan reports the header race, and a lost update husks a live parent.
//
// RED MEANS: an Unowned read the cursor proof accepts took a count again, or the proof accepted a read
//   across a call that may release.
//
// GUARD-TSAN
// GUARD-BALANCE Tree

class Tree {
	id: int32 = 0;
	name: string = "t";
	kids: Vec<Owned<Tree>> = [];
	up: Unowned<Tree> | null = null;
}

function grow(depth: int32, width: int32): Owned<Tree> {
	const root: Owned<Tree> = new Tree();
	let level: Tree[] = [root];
	let next = 1;
	for (let d = 0; d < depth; d += 1) {
		const below: Tree[] = [];
		for (const parent of level) {
			for (let w = 0; w < width; w += 1) {
				const kid: Owned<Tree> = new Tree();
				kid.id = next;
				next += 1;
				kid.up = parent;
				below.push(kid);
				parent.kids.push(move kid);
			}
		}
		level = below;
	}
	return root;
}

function nameLength(t: Readonly<Tree>): int32 {
	return t.name.length;
}

function depthOf(t: Readonly<Tree>): int32 {
	let d = 0;
	let at = t;
	while (at.up != null) {
		d += nameLength(at.up) + at.up.id - at.up.id;
		at = at.up;
	}
	return d;
}

function parentId(t: Readonly<Tree>): int32 {
	const p = t.up;
	return p != null ? p.id + nameLength(p) - 1 : -1;
}

function walk(t: Readonly<Tree>): int32 {
	let sum = depthOf(t) + parentId(t);
	for (const k of t.kids) sum += walk(k);
	return sum;
}

async function main(): Promise<void> {
	const root = grow(4, 4);
	const expected = walk(root);
	for (let round = 0; round < 20; round += 1) {
		const tasks: Promise<int32>[] = [];
		for (let i = 0; i < 8; i += 1) tasks.push(spawn((): int32 => walk(root)));
		for (const t of tasks) {
			if ((await t) != expected) {
				console.log("GUARD-FAIL a worker read another sum");
				return;
			}
		}
	}
	console.log("GUARD-OK");
}
await main();
