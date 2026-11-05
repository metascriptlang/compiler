// @exit: 1
// @skip-js: C-only by design: the check runs when the DRC frees the target; JS frees nothing
// @stdout: seen 9
// @stdout: N destroyed 3
// @stdout: Error: 1 Unowned<N> edge(s) still point at the N being freed; each would dangle
// note: edges cleared before their target drops never stop the program; module globals are destroyed in reverse declaration order, so a global target declared after its holder is freed first while the holder's edge still points at it, and the program stops at exit.
class N { id: int32 = 0; }
class H { at: Unowned<N> | null = null; }
let destroyedN = 0;
function onDestroy(this n: N): void { destroyedN++; }
const h: H = new H();
function step(i: int32): void {
	const n: N = new N();
	n.id = i;
	h.at = n;
	h.at = null;
}
for (let i = 0; i < 3; i++) step(i);
const keep: N = new N();
keep.id = 9;
h.at = keep;
const seen = h.at;
if (seen != null) console.log("seen " + seen.id.toString());
console.log("N destroyed " + destroyedN.toString());
