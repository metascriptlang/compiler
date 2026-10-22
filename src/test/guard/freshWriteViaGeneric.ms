// nim-guard: a write through the result of a generic routine that returns new
//
// INVARIANT (NIM-REF AN-36, twin variant v2, no twin): a field write through a local rooted at mkVia<T>(), which returns the generic mk0<T>() that returns new, frees nothing a view elsewhere holds.
//
// WHAT IT CATCHES: const view = globalBox.data; const t = mkVia(2); t.data = ... (inline and in a callee). The churn after the write reuses a freed block,
//   so a dangling read prints other bytes and the guard exits 1 without ASan.
//
// RED MEANS: the fresh-result bit marked a routine fresh when one of its returns is shared, or a fresh-root write freed a viewed slot. Read the freshness inference and the cursor refusal.
// GUARD-BALANCE TOTAL
// GUARD-JS

let got = "";
function note(s: string): void { got += s + ";"; }
function churn(): void {
	const keep: string[] = [];
	for (let i = 0; i < 48; i += 1) keep.push(`w${i % 10}` + "#".repeat(24 + i % 16));
}

class Fr2Box<T> { data: string = ""; v: T; constructor(v: T) { this.v = v; } }
const globalBox = new Fr2Box<int32>(1);
globalBox.data = "a" + "x".repeat(30);
function mk0<T>(v: T): Fr2Box<T> { return new Fr2Box<T>(v); }
function mkVia<T>(v: T): Fr2Box<T> { return mk0<T>(v); }
function fill(): int64 {
	const t = mkVia<int32>(3);
	t.data = "z" + "q".repeat(40);
	return t.data.length;
}
function main(): void {
	const view = globalBox.data;
	const t = mkVia<int32>(2);
	t.data = "z" + "q".repeat(40);
	churn();
	note(`${view.length} ${view.substring(0, 4)} ${t.data.length} ${t.v}`);
	const n = fill();
	churn();
	note(`${view.length} ${view.substring(0, 4)} ${n}`);
}
main();

if (got == "31 axxx 41 2;31 axxx 41;") {
	console.log("GUARD-OK");
} else {
	console.log(`GUARD-RED got=${got}`);
	process.exit(1);
}
