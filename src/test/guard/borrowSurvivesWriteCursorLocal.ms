// nim-guard: a local view of a field another alias overwrites
//
// INVARIANT (NIM-REF AN-36, twin n20cursorLocal (clean control)): a local read of box.s stays alive when a callee writes the same field through a global alias of box.
//
// WHAT IT CATCHES: const t = box.s; mutate() where mutate writes gbox!.s and gbox == box. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a cursor survived a call or assignment that may write its source path. Read the cursor refusal in analyzer/cursors.ms and the summary in checker/writeEffects.ms.
// GUARD-BALANCE Bw20Box
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Bw20Box { s: string = ""; }
let gbox: Bw20Box | null = null;
function mutate(): void { gbox!.s = "z" + "q".repeat(40); }
function main(): void {
	const box = new Bw20Box();
	box.s = "a" + "x".repeat(30);
	gbox = box;
	const t = box.s;
	mutate();
	churn();
	note(`${t.length} ${t.substring(0, 4)}`);
	gbox = null;
}
main();

if (got == "31 axxx;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
