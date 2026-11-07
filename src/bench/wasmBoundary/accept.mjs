import { readFileSync } from "node:fs";

const NOISE = 1.10;
const BARS = ["neon", "wasmbindgen"];
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

const bars = BARS.filter((arm) => rows.some((row) => median(arm, row) !== null));
if (bars.length === 0) {
	console.log(`accept: no comparable arm in ${path}; run with arms ${BARS.join(" or ")}`);
	process.exit(2);
}
let missed = 0;
console.log("row".padEnd(28) + "mixed".padStart(12) + bars.map((b) => b.padStart(14)).join("") + "  verdict");
for (const row of rows) {
	const ours = median("mixed", row);
	if (ours === null) continue;
	const misses = bars.filter((b) => { const bar = median(b, row); return bar !== null && ours > bar * NOISE; });
	missed += misses.length > 0 ? 1 : 0;
	const cells = bars.map((b) => { const bar = median(b, row); return (bar === null ? "-" : bar.toString()).padStart(14); }).join("");
	console.log(row.padEnd(28) + ours.toString().padStart(12) + cells + "  " + (misses.length === 0 ? "ok" : "slower than " + misses.join(", ")));
}
console.log(`accept: ${rows.length - missed}/${rows.length} rows meet ${bars.join(" and ")} (mixed at most ${Math.round((NOISE - 1) * 100)}% above)`);
process.exit(missed === 0 ? 0 : 1);
