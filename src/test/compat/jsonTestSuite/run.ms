// JSONTestSuite conformance: every file of the vendored suite is parsed with JSON.parseValue and
// compared with node's row in node.tsv (verdict, and the stringified value when accepted), or with
// the row in decided.tsv where a decision overrides node. A y_ file must parse and an n_ file must not.
// Usage, from the repository root: msc run [--target=js|raiser] src/test/compat/jsonTestSuite/run.ms

import { argv, exit } from "std/process";
import { readFile, readDir } from "std/fs";
import { Map } from "std/core/struct";

interface Expected { verdict: string; value: string; }

const root = argv.length > 1 ? argv[1] : "src/test/compat/jsonTestSuite";

function readOrExit(path: string): string {
	const r = readFile(path);
	if (!r.ok) {
		console.log(`jsonTestSuite: cannot read ${path}: ${r.error.message}`);
		exit(2);
	}
	return r.value;
}

function rowsOf(path: string): string[][] {
	const rows: string[][] = [];
	for (const line of readOrExit(path).split("\n")) {
		if (line != "") rows.push(line.split("\t"));
	}
	return rows;
}

const expected = new Map<string, Expected>();
for (const row of rowsOf(`${root}/node.tsv`)) expected.set(row[0], { verdict: row[1], value: row[2] });
let decided = 0;
for (const row of rowsOf(`${root}/decided.tsv`)) {
	expected.set(row[0], { verdict: "accept", value: row[1] });
	decided = decided + 1;
}

let files = 0;
const failures: string[] = [];
for (const group of ["test_parsing", "test_transform"]) {
	const names = readDir(`${root}/suite/${group}`);
	names.sort();
	for (const name of names) {
		if (!name.endsWith(".json")) continue;
		files = files + 1;
		const key = `${group}/${name}`;
		const parsed = JSON.parseValue(readOrExit(`${root}/suite/${key}`));
		const verdict = parsed.ok ? "accept" : "reject";
		const value = parsed.ok ? stringify(parsed.value) : "";
		const want = expected.get(key);
		if (want == null) {
			failures.push(`${key}: no row in node.tsv; rerun oracle.mjs`);
		} else if (group == "test_parsing" && name.startsWith("y_") && verdict != "accept") {
			failures.push(`${key}: must parse, got ${parsed.ok ? "" : parsed.error}`);
		} else if (group == "test_parsing" && name.startsWith("n_") && verdict != "reject") {
			failures.push(`${key}: must be refused, got ${value}`);
		} else if (verdict != want.verdict) {
			failures.push(`${key}: ${verdict}, node ${want.verdict}`);
		} else if (verdict == "accept" && value != want.value) {
			failures.push(`${key}: ${value}, expected ${want.value}`);
		}
	}
}

for (const f of failures) console.log(`  DIFF ${f}`);
console.log(`jsonTestSuite: ${files} files, ${failures.length} differ, ${decided} decided`);
if (failures.length > 0) exit(1);
