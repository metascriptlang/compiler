// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @skip-js: Arc<T> has no js binding (atomic-rc box is C-only, PARALOCK tier 2/3) - same as 405/406/414
// note: an Arc's interior is shared and immutable, so it binds no `ref`/`out` parameter (handoff
// storageMutability "an Arc interior binds no ref or out parameter"); the handle slot itself is the
// caller's own storage, so passing it to `ref a: Arc<T>` and rebinding it stays legal, as does a plain
// local through `ref` and `this ref`. Prints `3 9 5` on every lane that runs it.
struct Ctr { n: int32; }
function bump(ref c: Ctr): void { c.n = 9; }
function heal(this ref c: Ctr): void { c.n = c.n - 4; }
function swap(ref a: Arc<Ctr>): void { a = new Arc({ n: 3 }); }
function run(): void {
	let shared: Arc<Ctr> = new Arc({ n: 1 });
	swap(shared);
	let local: Ctr = { n: 0 };
	bump(local);
	const before = local.n;
	local.heal();
	console.log(`${shared.n} ${before} ${local.n}`);
}
run();
