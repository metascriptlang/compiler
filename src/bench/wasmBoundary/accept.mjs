import { readFileSync } from "node:fs";

const NOISE = 1.10;
const PAIRS = [["mixed", "wasmbindgen", "node"], ["mixed-chrome", "wasmbindgen-chrome", "chrome"]];
const REFERENCE = "neon";
const PARKED = new Map([["node\tprimes 2M", "compiler card 2026-11-08-wasm-sieve-13-percent-behind-rust-wasm"]]);
const path = process.argv[2] ?? "out/bench/wasmBoundary/runs.tsv";

const values = new Map();
const rows = [];
for (const line of readFileSync(path, "utf8").split("\n")) {
	const [arm, row, value] = line.split("\t");
	if (!row || !value || Number.isNaN(Number(value))) continue;
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
	let parkedMisses = 0;
	console.log(`${runtime}: ${ours} against ${bar}` + (ref ? ` (${REFERENCE}, native and Node-only, shown for reference)` : ""));
	console.log("row".padEnd(28) + ours.padStart(14) + bar.padStart(20) + (ref ? REFERENCE.padStart(14) : "") + "  verdict");
	for (const row of rows) {
		const mine = median(ours, row);
		const theirs = median(bar, row);
		if (mine === null || theirs === null) continue;
		const ok = mine <= theirs * NOISE;
		const parked = PARKED.get(runtime + "\t" + row);
		missed += ok || parked ? 0 : 1;
		parkedMisses += !ok && parked ? 1 : 0;
		const verdict = parked ? (ok ? "ok, parked on " + parked + ": unpark it" : "slower, parked on " + parked) : ok ? "ok" : "slower than " + bar;
		console.log(row.padEnd(28) + cell(mine) + cell(theirs).padStart(20) + (ref ? cell(median(REFERENCE, row)) : "") + "  " + verdict);
	}
	const total = rows.filter((row) => median(ours, row) !== null && median(bar, row) !== null).length;
	console.log(`accept ${runtime}: ${total - missed - parkedMisses}/${total} rows meet ${bar} (${ours} at most ${Math.round((NOISE - 1) * 100)}% above)` + (parkedMisses ? `, ${parkedMisses} slower row(s) parked on a card` : ""));
	failed ||= missed > 0;
}
process.exit(failed ? 1 : 0);
