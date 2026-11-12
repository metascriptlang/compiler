// A top-level script that lends its own module state to a task names that state once
//
// INVARIANT (ULTRALOCK V0): module state crosses threads only as a const value, a Locked<T> or an
//   Arc<T>. At the top level a script's own bindings are module state, so the value a callee lends
//   to its task is refused as that state itself, and a thunk that reads one is refused once, by
//   the walk of the thunk.
//
// WHAT IT CATCHES: a module array passed at the top level to a routine that lends it to its tasks,
//   and a module binding a top-level thunk reads.
//
// RED MEANS: the refusal describes the value as holding itself, or the same thunk is refused twice.
//
// GUARD-JS
// GUARD-CHECK-FAIL 'ROW' is lent to the spawn
// GUARD-CHECK-FAIL but it is module-level 'ROW'
// GUARD-CHECK-FAIL spawn runs this thunk on another thread, but it uses module-level 'first'

class Node { v: int32 = 1; }
const ROW: Node[] = [new Node()];
async function sumOf(ns: Node[]): Promise<int32> {
	const jobs: Promise<int32>[] = [];
	for (const n of ns) jobs.push(spawn(() => n.v));
	let total: int32 = 0;
	for (const j of jobs) total += await j;
	return total;
}
ROW[0].v = 5;
console.log(await sumOf(ROW)); // GUARD-REFUSED
const first = ROW[0];
console.log(await spawn((): int32 => first.v)); // GUARD-REFUSED
