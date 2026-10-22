// nim-guard: a spawned worker writes through a routine result that is stored in a module global
//
// INVARIANT (NIM-REF AN-36, twin variant stored+spawn, no twin): a worker calls mk(), which stores its new object in globalNode, and writes a field through the result; views the parent took of globalNode.data before the spawn stay alive.
//
// WHAT IT CATCHES: const view = globalNode.data; await spawn(() => { const t = mk(); t.data = ...; }), twice. The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: the fresh-result bit marked a routine fresh when one of its returns is shared, or a fresh-root write freed a viewed slot. Read the freshness inference and the cursor refusal.
// GUARD-BALANCE Fr6Node
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Fr6Node { data: string = ""; }
let globalNode = new Fr6Node();
globalNode.data = "a" + "x".repeat(30);
function mk(): Fr6Node {
	const n = new Fr6Node();
	n.data = "b" + "x".repeat(30);
	globalNode = n;
	return n;
}
async function main(): Promise<void> {
	const view = globalNode.data;
	const n = await spawn((): int64 => {
		const t = mk();
		t.data = "z" + "q".repeat(40);
		return t.data.length;
	});
	churn();
	note(`${view.length} ${view.substring(0, 4)} ${n} ${globalNode.data.substring(0, 2)}`);
	const view2 = globalNode.data;
	const m = await spawn((): int64 => {
		const t = mk();
		t.data = "y" + "p".repeat(41);
		return t.data.length;
	});
	churn();
	note(`${view2.length} ${view2.substring(0, 4)} ${m} ${globalNode.data.substring(0, 2)}`);
}
await main();

if (got == "31 axxx 41 zq;41 zqqq 42 yp;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
