// @exit: 1
// @skip-js: C-only by design: the check runs when the DRC frees the target; JS frees nothing
// @stdout: attached 7
// @stdout: Error: 1 Unowned<N> edge(s) still point at the N being freed; each would dangle
// note: a target freed while an Unowned<T> edge still points at it stops the program at the free, before the edge can be read.
class N { id: int32 = 7; }
class H { at: Unowned<N> | null = null; }
let h: H = new H();
function attach(): void {
	const n: N = new N();
	h.at = n;
	console.log("attached " + n.id.toString());
}
attach();
console.log("unreachable");
