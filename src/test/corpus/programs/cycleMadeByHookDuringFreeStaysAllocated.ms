// @stdout: done
// A destroy hook that builds a cycle during the free loop: that pass does not collect it, so
// the new pair stays allocated until a later collection, never freed while reachable.
class Pair {
	other: Pair | null = null;
}
class Dying {
	self: Dying | null = null;
	onDestroy(): void {
		const a = new Pair();
		const b = new Pair();
		a.other = b;
		b.other = a;
	}
}
function make(): void {
	const d = new Dying();
	d.self = d;
}
function main(): void {
	for (let i: int32 = 0; i < 3000; i += 1) make();
	console.log("done");
}
main();
