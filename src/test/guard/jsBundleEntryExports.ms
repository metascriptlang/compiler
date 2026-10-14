// `msc build --target=js entry.ms` exposes the entry module's exports as the bundle's ES
// exports under their source names (`export default` included); a sibling module's
// export of the same name stays internal, an overload set has no single JS value and is
// left out, and an entry without a runtime export gets no export statement.
//
// WHY A SUBPROCESS: the observable is the bundle as a host imports it, which no
// in-process test reaches. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: node sees `[ 'default', 'module.exports' ]` and no `respond`.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, readFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardJsBundleEntryExports`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function build(entry: string, out: string): boolean {
	const r = execFileResult(msc, ["build", "--target=js", entry, `--output=${out}`], dir);
	if (r.exitCode != 0) report(`build ${entry}: ${r.output}${r.errorOutput}`);
	return r.exitCode == 0;
}

function host(script: string, want: string): void {
	writeFile(`${dir}/host.mjs`, script);
	const r = execFileResult("node", ["host.mjs"], dir);
	const all = `${r.output}${r.errorOutput}`;
	if (r.exitCode != 0 || !r.output.includes(want)) report(`want ${want}, got: ${all}`);
}

removeAll(dir);
ensureDir(`${dir}/app/src`);
writeFile(`${dir}/app/src/lib.ms`, [
	"export function respond(): string { return \"lib\"; }",
	"export function suffix(): string { return \"!\"; }",
	"",
].join("\n"));
writeFile(`${dir}/app/src/main.ms`, [
	"import { suffix } from \"./lib\";",
	"export struct Point { x: int32; y: int32; }",
	"export function respond(path: string): string { return \"page \" + path + suffix(); }",
	"export function shift(p: Point, d: int32): Point { return { x: p.x + d, y: p.y + d }; }",
	"export const version = 3;",
	"export function tag(n: int32): string { return \"n\"; }",
	"export function tag(s: string): string { return \"s\"; }",
	"function fetch(path: string): string { return respond(path); }",
	"export default { fetch };",
	"",
].join("\n"));
writeFile(`${dir}/plain.ms`, "function twice(n: int32): int32 { return n * 2; }\nexport interface Shape { w: int32; }\nconsole.log(twice(2));\n");

if (build("app/src/main.ms", "app.js")) {
	host([
		"import * as m from \"./app.js\";",
		"const p = m.shift({ x: 1, y: 2 }, 10);",
		"console.log(Object.keys(m).sort().join(\",\"), m.respond(\"/x\"), m.version, p.x, p.y, m.default.fetch(\"/y\"));",
		"",
	].join("\n"), "default,respond,shift,version page /x! 3 11 12 page /y!");
}
if (build("plain.ms", "plain.js")) {
	const plain = readFile(`${dir}/plain.js`);
	if (!plain.ok || plain.value.contains("export {")) report("an entry without a runtime export got an export statement");
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
