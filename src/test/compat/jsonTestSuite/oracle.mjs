import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const rows = [];
for (const group of ["test_parsing", "test_transform"]) {
	const dir = path.join(here, "suite", group);
	for (const name of fs.readdirSync(dir).sort()) {
		if (!name.endsWith(".json")) continue;
		const text = fs.readFileSync(path.join(dir, name), "utf8");
		let row;
		try {
			row = `${group}/${name}\taccept\t${JSON.stringify(JSON.parse(text))}`;
		} catch {
			row = `${group}/${name}\treject\t`;
		}
		rows.push(row);
	}
}
fs.writeFileSync(path.join(here, "node.tsv"), rows.join("\n") + "\n");
console.log(`node.tsv: ${rows.length} rows from node ${process.version}`);
