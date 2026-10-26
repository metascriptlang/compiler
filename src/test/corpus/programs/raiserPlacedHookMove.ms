// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: 3 5 1 1
struct ByRef { id: int32; n: int32; }
struct ByVar { id: int32; n: int32; }

let refMoves: int32 = 0;
let varMoves: int32 = 0;

function onMove(this ref dest: ByRef, src: ByRef): void { refMoves += 1; dest.id = src.id; dest.n = src.n; }
function onMove(this dest: Var<ByVar>, src: ByVar): void { varMoves += 1; dest.id = src.id; dest.n = src.n; }

function mkRef(i: int32): ByRef { return { id: i, n: i + 2 }; }
function mkVar(i: int32): ByVar { return { id: i, n: i + 2 }; }

function run(): string {
	let a: ByRef = mkRef(1);
	a = mkRef(3);
	let b: ByVar = mkVar(1);
	b = mkVar(4);
	return a.id.toString() + " " + (b.n - 1).toString();
}

console.log(run() + " " + refMoves.toString() + " " + varMoves.toString());
