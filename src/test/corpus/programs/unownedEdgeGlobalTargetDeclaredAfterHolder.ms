// @skip-js: C-only by design: onDestroy counts the DRC's destroys; JS frees nothing
// @stdout: seen 9
// @stdout: N destroyed 3
// note: edges cleared before their target drops never stop the program; module globals are destroyed in reverse declaration order, so a global target declared after its holder is destroyed first while the holder's edge still points at it, keeps its memory until the holder goes, and the program exits cleanly because nothing reads the edge.
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
