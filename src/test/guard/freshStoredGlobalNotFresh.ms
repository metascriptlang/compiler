// nim-guard: a routine that returns new after storing it in a module global is not fresh
//
// INVARIANT (NIM-REF AN-36, twin variant stored, no twin): mk() allocates, stores the object in globalNode and returns it; a field write through its result keeps a live view of globalNode.data alive.
//
// WHAT IT CATCHES: const t = mk(); const view = globalNode.data; t.data = ... (inline and in a callee), plus a view of the replaced node taken before mk(). The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: the fresh-result bit marked a routine fresh when one of its returns is shared, or a fresh-root write freed a viewed slot. Read the freshness inference and the cursor refusal.
// GUARD-BALANCE Fr5Node
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Fr5Node { data: string = ""; }
let globalNode = new Fr5Node();
globalNode.data = "a" + "x".repeat(30);
function mk(): Fr5Node {
	const n = new Fr5Node();
	n.data = "b" + "x".repeat(30);
	globalNode = n;
	return n;
}
function fill(): int64 {
	const t = mk();
	t.data = "y" + "p".repeat(41);
	return t.data.length;
}
function main(): void {
	const before = globalNode.data;
	const t = mk();
	const view = globalNode.data;
	t.data = "z" + "q".repeat(40);
	churn();
	note(`${before.length} ${before.substring(0, 4)} ${view.length} ${view.substring(0, 4)} ${globalNode.data.substring(0, 2)}`);
	const view2 = globalNode.data;
	const n = fill();
	churn();
	note(`${view2.length} ${view2.substring(0, 4)} ${n} ${globalNode.data.substring(0, 2)}`);
}
main();

if (got == "31 axxx 31 bxxx zq;41 zqqq 42 yp;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
