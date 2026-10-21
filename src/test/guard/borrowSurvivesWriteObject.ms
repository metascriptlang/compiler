// nim-guard: a callee that replaces the global struct it borrows
//
// INVARIANT (NIM-REF AN-36, twin n08obj (UAF)): a struct argument borrowed from a module variable keeps its value when the callee assigns a new struct to it.
//
// WHAT IT CATCHES: swap(g) where swap assigns g = { ... } first. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a borrowed argument whose source the callee may write was not copied into an owned temp. Read processCall in inject.ms and the callee's summary in checker/writeEffects.ms.
// GUARD-BALANCE TOTAL

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

struct Bw8P { name: string; }
let g: Bw8P = { name: "first" + "x".repeat(20) };
function swap(p: Bw8P): void {
	g = { name: "second" + "x".repeat(20) };
	churn();
	note(p.name.substring(0, 8));
}
swap(g);
swap(g);

if (got == "firstxxx;secondxx;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
