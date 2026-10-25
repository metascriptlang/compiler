// nim-guard: a callee that overwrites the array element it borrows from
//
// INVARIANT (NIM-REF AN-36, twin n05elem (UAF)): an argument borrowed from arr[0] stays alive when the callee writes arr[0].
//
// WHAT IT CATCHES: show(arr[0]) where show assigns arr[0] first. The churn after the write reuses a freed block,
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

const arr: string[] = [""];
function show(text: string): void {
	arr[0] = text + "y";
	churn();
	note(`${text.length} ${text.substring(0, 8)}`);
}
show(`config:${"x".repeat(24)}`);
show(arr[0]);

if (got == "31 config:x;32 config:x;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
