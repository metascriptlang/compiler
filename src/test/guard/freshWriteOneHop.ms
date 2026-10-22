// nim-guard: a write through the result of a routine that returns another fresh routine's result
//
// INVARIANT (NIM-REF AN-36, twin variant v1, no twin): a field write through a local rooted at mk(), where mk returns mk0() and mk0 returns new, frees nothing a view elsewhere holds.
//
// WHAT IT CATCHES: const view = globalNode.data; const t = mk(); t.data = ... (inline and in a callee). The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: the fresh-result bit marked a routine fresh when one of its returns is shared, or a fresh-root write freed a viewed slot. Read the freshness inference and the cursor refusal.
// GUARD-BALANCE Fr1Node
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Fr1Node { data: string = ""; }
const globalNode = new Fr1Node();
globalNode.data = "a" + "x".repeat(30);
function mk0(): Fr1Node { return new Fr1Node(); }
function mk(): Fr1Node { return mk0(); }
function fill(): int64 {
	const t = mk();
	t.data = "z" + "q".repeat(40);
	return t.data.length;
}
function main(): void {
	const view = globalNode.data;
	const t = mk();
	t.data = "z" + "q".repeat(40);
	churn();
	note(`${view.length} ${view.substring(0, 4)} ${t.data.length}`);
	const n = fill();
	churn();
	note(`${view.length} ${view.substring(0, 4)} ${n}`);
}
main();

if (got == "31 axxx 41;31 axxx 41;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
