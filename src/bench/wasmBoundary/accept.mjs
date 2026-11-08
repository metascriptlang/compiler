import { readFileSync } from "node:fs";

const NOISE = 1.10;
const PAIRS = [["mixed", "wasmbindgen", "node"], ["mixed-chrome", "wasmbindgen-chrome", "chrome"]];
const REFERENCE = "neon";
const path = process.argv[2] ?? "out/bench/wasmBoundary/runs.tsv";

const values = new Map();
const rows = [];
for (const line of readFileSync(path, "utf8").split("\n")) {
	const [arm, row, value] = line.split("\t");
	if (!row || value === undefined || Number.isNaN(Number(value))) continue;
	if (!rows.includes(row)) rows.push(row);
	const key = arm + "\t" + row;
	if (!values.has(key)) values.set(key, []);
	values.get(key).push(Number(value));
}

function median(arm, row) {
	const list = values.get(arm + "\t" + row);
	if (!list) return null;
	const sorted = [...list].sort((a, b) => a - b);
	const mid = sorted.length >> 1;
	return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

const present = (arm) => rows.some((row) => median(arm, row) !== null);
const pairs = PAIRS.filter(([ours, bar]) => present(ours) && present(bar));
if (pairs.length === 0) {
	console.log(`accept: no runtime has both arms of a pair in ${path}; run with ${PAIRS.map((p) => p[0] + " and " + p[1]).join(", or ")}`);
	process.exit(2);
}
const cell = (v) => (v === null ? "-" : v.toString()).padStart(14);
let failed = false;
for (const [ours, bar, runtime] of pairs) {
	const ref = runtime === "node" && present(REFERENCE);
	let missed = 0;
	console.log(`${runtime}: ${ours} against ${bar}` + (ref ? ` (${REFERENCE}, native and Node-only, shown for reference)` : ""));
	console.log("row".padEnd(28) + ours.padStart(14) + bar.padStart(20) + (ref ? REFERENCE.padStart(14) : "") + "  verdict");
	for (const row of rows) {
		const mine = median(ours, row);
		const theirs = median(bar, row);
		if (mine === null || theirs === null) continue;
		const ok = mine <= theirs * NOISE;
		missed += ok ? 0 : 1;
		console.log(row.padEnd(28) + cell(mine) + cell(theirs).padStart(20) + (ref ? cell(median(REFERENCE, row)) : "") + "  " + (ok ? "ok" : "slower than " + bar));
	}
	const total = rows.filter((row) => median(ours, row) !== null && median(bar, row) !== null).length;
	console.log(`accept ${runtime}: ${total - missed}/${total} rows meet ${bar} (${ours} at most ${Math.round((NOISE - 1) * 100)}% above)`);
	failed ||= missed > 0;
}
process.exit(failed ? 1 : 0);
