// nim-guard: a callee that replaces the array it borrows
//
// INVARIANT (NIM-REF AN-36, twin n06seq (UAF)): an array argument borrowed from a module variable stays alive when the callee replaces that variable.
//
// WHAT IT CATCHES: keep(held) where keep assigns a new array to held first. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a borrowed argument whose source the callee may write was not copied into an owned temp. Read processCall in inject.ms and the callee's summary in checker/writeEffects.ms.
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

let held: number[] = [];
function keep(a: number[]): void {
	held = [a.length + 10, 2, 3];
	churn();
	note(`${a.length} ${a[0]}`);
}
keep([7, 8, 9]);
keep(held);

if (got == "3 7;3 13;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
