// nim-guard: a local view of a module variable a callee overwrites
//
// INVARIANT (NIM-REF AN-36, twin n21cursorGlobal (clean control)): a local read of a module variable stays alive when a callee assigns the variable.
//
// WHAT IT CATCHES: const t = notice; mutate() where mutate assigns notice. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a cursor survived a call or assignment that may write its source path. Read the cursor refusal in analyzer/cursors.ms and the summary in checker/writeEffects.ms.
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

let notice = "a" + "x".repeat(30);
function mutate(): void { notice = "z" + "q".repeat(40); }
function main(): void {
	const t = notice;
	mutate();
	churn();
	note(`${t.length} ${t.substring(0, 4)}`);
}
main();

if (got == "31 axxx;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
