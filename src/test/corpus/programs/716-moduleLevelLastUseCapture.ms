// Parity program — a module-level binding introduced by destructuring, then
// captured into a closure env, was classified last-use and moved (bug: lambda
// lifting wraps a last-use capture in a synthetic MoveExpr, and the last-use scan
// only walked the remaining statements of the current list — blind to a global's
// readers in other functions, at teardown, and to the temp the destructuring
// lowering keeps alive beside it, so the build died with "cannot move 'p'").
// Heap strings churned in a loop so the ledger sees the captured value's
// copy/destroy traffic rather than a single dispatch.
//
// @stdout: cap=alphabeta
// @exit: 0

function pair(): [string, string] { return ["alpha", "beta"]; }
const [p, q] = pair();
const readP = () => p;

function sig(init: string): [() => string, (v: string) => void] {
	let v = init;
	return [() => v, (nv: string) => { v = nv; }];
}
const [get, set] = sig("seed");
const readGet = () => get();

function main(): void {
	let acc = "";
	for (let i = 0; i < 200; i += 1) {
		acc = readP() + q;
	}
	console.log("cap=" + acc);

	set("changed");
	let tail = "";
	for (let i = 0; i < 200; i += 1) {
		tail = readGet();
	}
	console.log("sig=" + tail);
}
