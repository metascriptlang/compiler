// nim-guard: a method that overwrites the field of this it is passed
//
// INVARIANT (NIM-REF AN-36, twin n12method (UAF)): an argument borrowed from this.s stays alive when the method assigns this.s.
//
// WHAT IT CATCHES: box.set(box.s) where set assigns this.s first. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: a borrowed argument whose source the callee may write was not copied into an owned temp. Read processCall in inject.ms and the callee's summary in checker/writeEffects.ms.
// GUARD-BALANCE Bw12Box
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Bw12Box {
	s: string = "";
	set(text: string): void {
		this.s = text + "y";
		churn();
		note(`${text.length} ${text.substring(0, 8)}`);
	}
}
function run(): void {
	const box = new Bw12Box();
	box.set(`config:${"x".repeat(24)}`);
	box.set(box.s);
}
run();

if (got == "31 config:x;32 config:x;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
