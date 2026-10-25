// A spawned worker that calls a routine storing its result in a module global would write that
// global while the parent's thread may read it, so the spawn is a compile error that names the
// callee and the global. The single-thread neighbours of the stored-result write are the
// borrowSurvivesWrite* guards.
//
// GUARD-CHECK-FAIL spawn runs this thunk on another thread, but it calls 'mk'
// GUARD-CHECK-FAIL which uses module-level 'globalNode'

class Fr6Node { data: string = ""; }
let globalNode = new Fr6Node();
function mk(): Fr6Node {
	const n = new Fr6Node();
	globalNode = n;
	return n;
}
async function main(): Promise<int64> {
	return await spawn((): int64 => {
		const t = mk();
		t.data = "z" + "q".repeat(40);
		return t.data.length;
	});
}
console.log(`${await main()}`);
