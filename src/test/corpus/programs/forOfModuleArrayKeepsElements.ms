// @stdout: ok ok ok|lanes=c/js/raiser rows=3 names=ab/cd|pairs=a=1,b=2 kept=a12

class Named { name: string; constructor(name: string) { this.name = name; } }

function commaList(text: string): string[] {
	const out: string[] = [];
	for (const item of text.split(",")) { if (item != "") out.push(item); }
	return out;
}
function rowsOf(n: int32): int32[][] {
	const out: int32[][] = [];
	for (let i: int32 = 0; i < n; i += 1) out.push([i, i + 1]);
	return out;
}
function namedOf(text: string): Named[] {
	const out: Named[] = [];
	for (const s of commaList(text)) out.push(new Named(s));
	return out;
}

const LANES: string[] = commaList("c,js,raiser");
const ROWS: int32[][] = rowsOf(3);
const NAMES: Named[] = namedOf("ab,cd");
const KNOWN: string[] = ["c", "js", "raiser"];
const PAIRS: string[][] = [["a", "1"], ["b", "2"]];

function has(items: string[], v: string): boolean {
	for (const s of items) { if (s == v) return true; }
	return false;
}
function checkLanes(): string {
	for (const lane of LANES) { if (!has(KNOWN, lane)) return "bad " + lane; }
	return "ok";
}
function checkRows(): string {
	for (const row of ROWS) { if (row.length != 2) return "bad row"; }
	return "ok";
}
function checkNames(): string {
	for (const named of NAMES) { if (named.name.length != 2) return "bad " + named.name; }
	return "ok";
}

const seen: string[] = [];
for (const [name, value] of PAIRS) seen.push(name + "=" + value);
console.log(`${checkLanes()} ${checkRows()} ${checkNames()}|lanes=${LANES.join("/")} rows=${ROWS.filter((r) => r.length == 2).length} names=${NAMES.map((n) => n.name).join("/")}|pairs=${seen.join(",")} kept=${PAIRS[0][0]}${PAIRS[0][1]}${PAIRS[1][1]}`);
