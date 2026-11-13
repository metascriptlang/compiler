// @exit: 1
// @skip-js: C-only by design: the check runs while the DRC destroys the target; JS frees nothing
// @stdout: start
// @stdout: Error: an Unowned<P> edge was read after its P was destroyed
// note: an object is dead to its Unowned<T> edges from the moment its destroy starts, also to an edge made during that destroy: here its own onDestroy stores `this` into an Unowned array, and a child destroyed with it reads the edge after some of its fields were released. Before, C read the half-destroyed object and printed "read p1a" (its `last` already released) while the Raiser stopped.
class P {
	first: string;
	kids: Owned<C>[] = [];
	last: string;
	constructor(name: string) { this.first = name + "a"; this.last = name + "z"; }
}
class C { tag: int32 = 0; }
class H { ups: Unowned<P>[] = []; }
const h = new H();
function onDestroy(this p: P): void { h.ups.push(p); }
function onDestroy(this c: C): void {
	if (h.ups.length > 0) {
		const q = h.ups[0];
		console.log("read " + q.first + q.last);
	}
}
function run(): void {
	const p = new P("p" + (1).toString());
	p.kids.push(new C());
}
console.log("start");
run();
console.log("unreachable " + h.ups.length.toString());
