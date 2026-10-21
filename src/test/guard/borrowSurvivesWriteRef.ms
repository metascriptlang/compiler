// nim-guard: a callee that replaces the global object it borrows
//
// INVARIANT (NIM-REF AN-36, twin n07ref (UAF)): an object argument borrowed from a module variable stays alive when the callee assigns a new object to it.
//
// WHAT IT CATCHES: swap(cur) where swap assigns cur = new Node first. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a borrowed argument whose source the callee may write was not copied into an owned temp. Read processCall in inject.ms and the callee's summary in checker/writeEffects.ms.
// GUARD-BALANCE Bw7Node
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Bw7Node { name: string; constructor(n: string) { this.name = n; } }
let cur: Bw7Node = new Bw7Node("first" + "x".repeat(20));
function swap(n: Bw7Node): void {
	cur = new Bw7Node("second" + "x".repeat(20));
	churn();
	note(n.name.substring(0, 8));
}
swap(cur);
swap(cur);

if (got == "firstxxx;secondxx;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
