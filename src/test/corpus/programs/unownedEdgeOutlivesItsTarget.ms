// @exit: 1
// @skip-js: C-only by design: onDestroy counts the DRC's destroys and the check runs when an edge is read after its target was destroyed; JS frees nothing
// @stdout: attached 7
// @stdout: destroyed 1, edge kept
// @stdout: Error: an Unowned<N> edge was read after its N was destroyed
// note: a target destroyed while an Unowned<T> edge still points at it is destroyed on time and keeps only its memory; reading the edge afterwards stops the program instead of reading the destroyed object.
class N { id: int32 = 7; }
let destroyed = 0;
function onDestroy(this n: N): void { destroyed++; }
class H { at: Unowned<N> | null = null; }
let h: H = new H();
function attach(): void {
	const n: N = new N();
	h.at = n;
	console.log("attached " + n.id.toString());
}
attach();
console.log("destroyed " + destroyed.toString() + ", edge kept");
const seen = h.at;
console.log("unreachable " + (seen != null ? seen.id : 0).toString());
