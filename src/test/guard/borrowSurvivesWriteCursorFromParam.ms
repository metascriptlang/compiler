// nim-guard: a local view of a parameter's field a callee overwrites
//
// INVARIANT (NIM-REF AN-36, twin n22cursorFromParam (UAF)): a local read of b.s, b a parameter bound to a global, stays alive when a callee writes gbox.s.
//
// WHAT IT CATCHES: const t = b.s; mutate() where mutate writes gbox.s and b is gbox. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a cursor survived a call or assignment that may write its source path. Read the cursor refusal in analyzer/cursors.ms and the summary in checker/writeEffects.ms.
// GUARD-BALANCE Bw22Box
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Bw22Box { s: string = ""; }
const gbox = new Bw22Box();
gbox.s = "a" + "x".repeat(30);
function mutate(): void { gbox.s = "z" + "q".repeat(40); }
function main(b: Bw22Box): void {
	const t = b.s;
	mutate();
	churn();
	note(`${t.length} ${t.substring(0, 4)}`);
}
main(gbox);

if (got == "31 axxx;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
