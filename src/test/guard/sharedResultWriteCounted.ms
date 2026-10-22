// nim-guard: a write through the result of a routine that returns a global
//
// INVARIANT (NIM-REF AN-36, twin variant shared, no twin): a field write through shared(), which returns globalNode, keeps a live view of globalNode.data alive.
//
// WHAT IT CATCHES: const view = globalNode.data; const t = shared(); t.data = ... (inline and in a callee). The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: the fresh-result bit marked a routine fresh when one of its returns is shared, or a fresh-root write freed a viewed slot. Read the freshness inference and the cursor refusal.
// GUARD-BALANCE Fr4Node
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Fr4Node { data: string = ""; }
const globalNode = new Fr4Node();
globalNode.data = "a" + "x".repeat(30);
function shared(): Fr4Node { return globalNode; }
function fill(): int64 {
	const t = shared();
	t.data = "y" + "p".repeat(41);
	return t.data.length;
}
function main(): void {
	const view = globalNode.data;
	const t = shared();
	t.data = "z" + "q".repeat(40);
	churn();
	note(`${view.length} ${view.substring(0, 4)} ${globalNode.data.substring(0, 2)}`);
	const view2 = globalNode.data;
	const n = fill();
	churn();
	note(`${view2.length} ${view2.substring(0, 4)} ${n} ${globalNode.data.substring(0, 2)}`);
}
main();

if (got == "31 axxx zq;41 zqqq 42 yp;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
