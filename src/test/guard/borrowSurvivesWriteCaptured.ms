// nim-guard: a closure that overwrites the captured variable it borrows from
//
// INVARIANT (NIM-REF AN-36, twin n02captured (UAF)): an argument borrowed from a captured local stays alive when the closure overwrites that capture.
//
// WHAT IT CATCHES: show(notice) where the closure show assigns its captured notice before reading the parameter. The churn after the write reuses a freed block,
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

function run(): void {
	let notice = "";
	const show = (text: string): void => {
		notice = text + "y";
		churn();
		note(`${text.length} ${text.substring(0, 8)}`);
	};
	show(`config:${"x".repeat(24)}`);
	show(notice);
}
run();

if (got == "31 config:x;32 config:x;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
