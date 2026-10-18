// `msc build --target=js entry.ms` exposes the entry module's exports as the bundle's ES
// exports under their source names: `export default`, named and star re-exports included;
// a sibling module's export of the same name stays internal, extension functions stay out
// without an error, and an entry without a runtime export gets no export statement. An
// exported name that is not one runtime value (overload set, generic function or class,
// enum, directly or re-exported) is a compile error at the `export`.
//
// WHY A SUBPROCESS: the observable is the bundle as a host imports it, which no
// in-process test reaches. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: node sees `[ 'default', 'module.exports' ]` and no `respond` (before
// 30482927f); on 30482927f the re-exports are missing and every refused kind builds.
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

function refused(source: string, want: string): void {
	writeFile(`${dir}/refused.ms`, `${source}\nconsole.log(1);\n`);
	const r = execFileResult(msc, ["build", "--target=js", "refused.ms", "--output=refused.js"], dir);
	const all = `${r.output}${r.errorOutput}`;
	if (r.exitCode == 0 || !all.includes(want) || !all.includes("refused.ms:1:1")) report(`want the error '${want}' at refused.ms:1:1 for: ${source}\ngot exit ${r.exitCode}: ${all}`);
}

removeAll(dir);
ensureDir(`${dir}/app/src`);
const libSource = [
	"export function respond(): string { return \"lib\"; }",
	"export function suffix(): string { return \"!\"; }",
	"export const limit = 9;",
	"export function pick(a: int32): int32 { return a; }",
	"export function pick(a: string): string { return a; }",
	"export function same<T>(x: T): T { return x; }",
	"export enum Color { Red, Blue }",
	"",
].join("\n");
writeFile(`${dir}/app/src/lib.ms`, libSource);
writeFile(`${dir}/lib.ms`, libSource);
writeFile(`${dir}/app/src/hub.ms`, "export function hubbed(): string { return \"hub\"; }\nexport const level = 4;\nexport struct Pair { a: int32; }\n");
writeFile(`${dir}/app/src/main.ms`, [
	"import { suffix } from \"./lib\";",
	"export { suffix, limit as cap } from \"./lib\";",
	"export * from \"./hub\";",
	"export struct Point { x: int32; y: int32; }",
	"export function respond(path: string): string { return \"page \" + path + suffix(); }",
	"export function shift(p: Point, d: int32): Point { return { x: p.x + d, y: p.y + d }; }",
	"export const version = 3;",
	"export function tag(this n: int32): string { return \"n\"; }",
	"export function tag(this s: string): string { return \"s\"; }",
	"function fetch(path: string): string { return respond(path); }",
	"export default { fetch };",
	"",
].join("\n"));
writeFile(`${dir}/plain.ms`, "function twice(n: int32): int32 { return n * 2; }\nexport interface Shape { w: int32; }\nconsole.log(twice(2));\n");

if (build("app/src/main.ms", "app.js")) {
	host([
		"import * as m from \"./app.js\";",
		"const p = m.shift({ x: 1, y: 2 }, 10);",
		"console.log(Object.keys(m).sort().join(\",\"), m.respond(\"/x\"), m.version, p.x, p.y, m.default.fetch(\"/y\"), m.suffix(), m.cap, m.hubbed(), m.level);",
		"",
	].join("\n"), "cap,default,hubbed,level,respond,shift,suffix,version page /x! 3 11 12 page /y! ! 9 hub 4");
}
if (build("plain.ms", "plain.js")) {
	const plain = readFile(`${dir}/plain.js`);
	if (!plain.ok || plain.value.contains("export {")) report("an entry without a runtime export got an export statement");
}

refused("export function o(a: int32): int32 { return a; }\nexport function o(a: string): string { return a; }", "cannot export 'o': it is an overload set of 2 functions");
refused("export function id<T>(x: T): T { return x; }", "cannot export 'id': it is a generic function");
refused("export class Box<T> { v: T; constructor(v: T) { this.v = v; } }", "cannot export 'Box': it is a generic class");
refused("export enum Mode { On, Off }", "cannot export 'Mode': it is an enum");
refused("export { pick } from \"./lib\";", "cannot export 'pick' (re-exported from './lib'): it is an overload set of 2 functions");
refused("export { same } from \"./lib\";", "cannot export 'same' (re-exported from './lib'): it is a generic function");
refused("export * from \"./lib\";", "cannot export 'Color' (re-exported from './lib'): it is an enum");

if (failed != 0) exit(1);
console.log("GUARD-OK");
