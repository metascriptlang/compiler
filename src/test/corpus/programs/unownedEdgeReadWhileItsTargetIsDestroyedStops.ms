// @exit: 1
// @skip-js: C-only by design: the check runs while the DRC destroys the target; JS frees nothing
// @stdout: start
// @stdout: Error: an Unowned<P> edge was read after its P was destroyed
// note: an Unowned<T> edge counts its target as destroyed from the moment the target's destroy starts: a child destroyed with its parent reads the parent through its back edge and stops, instead of reading fields the parent has already released or keeping the parent past its destroy.
class P {
	first: string;
	kids: Owned<C>[] = [];
	last: string;
	constructor(name: string) { this.first = name + "a"; this.last = name + "z"; }
}
class C { parent: Unowned<P> | null = null; }
const kept: P[] = [];
function onDestroy(this c: C): void {
	const p = c.parent;
	if (p != null) {
		console.log("unreachable " + p.first + p.last);
		kept.push(p);
	}
}
function run(): void {
	const p = new P("p" + (1).toString());
	const c = new C();
	c.parent = p;
	p.kids.push(c);
}
console.log("start");
run();
console.log("unreachable " + kept.length.toString());
