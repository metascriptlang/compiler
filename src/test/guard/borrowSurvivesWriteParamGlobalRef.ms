// nim-guard: a parameter bound to a global object the callee replaces
//
// INVARIANT (NIM-REF AN-36, twin n23paramGlobalRef (UAF)): a parameter bound to a module object, and a local read of its field, stay alive when a callee assigns a new object to the module variable.
//
// WHAT IT CATCHES: const t = b.s; mutate() where mutate assigns gbox = new Box and b is gbox. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a cursor survived a call or assignment that may write its source path. Read the cursor refusal in analyzer/cursors.ms and the summary in checker/writeEffects.ms.
// GUARD-BALANCE Bw23Box
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Bw23Box { s: string; constructor(s: string) { this.s = s; } }
let gbox = new Bw23Box("a" + "x".repeat(30));
function mutate(): void { gbox = new Bw23Box("z" + "q".repeat(40)); }
function main(b: Bw23Box): void {
	const t = b.s;
	mutate();
	churn();
	note(`${t.length} ${t.substring(0, 4)} ${b.s.substring(0, 4)}`);
}
main(gbox);

if (got == "31 axxx axxx;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
