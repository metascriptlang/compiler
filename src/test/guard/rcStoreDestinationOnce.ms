// nim-guard: an RC store evaluates its destination exactly once
//
// INVARIANT (injectdestructors.nim genOp/genSink: the hook receives the destination
//   once; stabilizeBracketIndex evaluates a non-atom index once; p(n[0]) walks the
//   destination before moveOrCopy): `a[f()] = x` and `recv().field = x` run `f` and
//   `recv` once, write the slot they name, and destroy the value that slot held.
//
// WHAT IT CATCHES: save-assign-destroy naming `dest` three times, so the index runs
//   again for the store and the incref (wrong slot, DOUBLE-DESTROY of DoLeaf), and a
//   call receiver on the left that is never walked (it runs twice and its owned
//   result is never released: DoHolder leaks).
//
// RED MEANS: the destination of an RC store drifted from Nim. Run /trace-nim on
//   processAssignment and stabilizeLocation in inject.ms.
// GUARD-BALANCE DoLeaf
// GUARD-BALANCE DoHolder
// GUARD-JS

class DoLeaf { v: string; constructor(v: string) { this.v = v; } }
class DoHolder {
	leaf: DoLeaf;
	n: int32 = 0;
	items: DoLeaf[] = [];
	constructor(l: DoLeaf) { this.leaf = l; }
}

let calls: int32 = 0;
function nextIdx(): int32 { calls += 1; return calls - 1; }
function pick(hs: DoHolder[]): DoHolder { calls += 1; return hs[0]; }

function run(): string {
	const hs: DoHolder[] = [new DoHolder(new DoLeaf("a"))];
	hs[0].items = [new DoLeaf("x"), new DoLeaf("y"), new DoLeaf("z")];
	let out = "";
	calls = 0;
	hs[0].items[nextIdx()] = new DoLeaf("q");
	out += calls + hs[0].items[0].v + hs[0].items[1].v + ",";
	calls = 0;
	pick(hs).leaf = new DoLeaf("b");
	out += calls + hs[0].leaf.v + ",";
	calls = 0;
	pick(hs).items[nextIdx()] = hs[0].leaf;
	out += calls + hs[0].items[0].v + hs[0].items[1].v + ",";
	calls = 0;
	pick(hs).n = 7;
	out += calls + "n" + hs[0].n + ",";
	const grid: DoLeaf[][] = [[new DoLeaf("g")], [new DoLeaf("h")]];
	calls = 0;
	grid[nextIdx()][nextIdx() - 1] = new DoLeaf("G");
	out += calls + grid[0][0].v + grid[1][0].v;
	return out;
}

if (run() == "1qy,1b,2qb,1n7,2Gh") {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
