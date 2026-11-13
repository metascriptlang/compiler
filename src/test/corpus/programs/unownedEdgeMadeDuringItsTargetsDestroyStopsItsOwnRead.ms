// @exit: 1
// @skip-js: C-only by design: the check runs while the DRC destroys the target; JS frees nothing
// @stdout: start
// @stdout: Error: an Unowned<P> edge was read after its P was destroyed
// note: an object's own onDestroy that stores `this` into an Unowned array and reads it back through that edge stops, as a read through an edge made before the destroy does. Before, C and the Raiser printed "read p1a".
class P {
	first: string;
	kids: Owned<C>[] = [];
	last: string;
	constructor(name: string) { this.first = name + "a"; this.last = name + "z"; }
}
class C { tag: int32 = 0; }
class H { ups: Unowned<P>[] = []; }
const h = new H();
function onDestroy(this p: P): void {
	h.ups.push(p);
	const q = h.ups[0];
	console.log("read " + q.first);
}
function run(): void { const p = new P("p" + (1).toString()); }
console.log("start");
run();
console.log("unreachable");
