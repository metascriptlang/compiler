import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardJsSplitPublicExports`;
let failed = 0;

function check(entry: string, output: string, script: string, want: string): void {
	const built = execFileResult(msc, ["build", "--target=js", "--split", entry, `--output=${output}`], dir);
	if (built.exitCode != 0) {
		console.log(`GUARD-FAIL ${entry}: ${built.output}${built.errorOutput}`);
		failed += 1;
		return;
	}
	writeFile(`${dir}/host.mjs`, script);
	const host = execFileResult("node", ["host.mjs"], dir);
	if (host.exitCode != 0 || host.output.trim() != want) {
		console.log(`GUARD-FAIL ${entry}: want ${want}, got ${host.output}${host.errorOutput}`);
		failed += 1;
	}
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/other.ms`, "export function respond(path: string): string { return \"other \" + path; }\n");
writeFile(`${dir}/third.ms`, "export function respond(path: string): string { return \"third \" + path; }\n");
for (const reverse of [false, true]) {
	const imports = reverse
		? "import { respond as third } from \"./third\";\nimport { respond as other } from \"./other\";"
		: "import { respond as other } from \"./other\";\nimport { respond as third } from \"./third\";";
	const out = reverse ? "reverse" : "forward";
	writeFile(`${dir}/main.ms`, imports + "\nfunction echo(respond: string): string { return respond; }\nexport function respond(path: string): string { return \"main \" + echo(path) + \" / \" + other(path) + \" / \" + third(path); }\n");
	check("main.ms", out, [
		`import { respond } from "./${out}/main.js";`,
		`import { respond as other } from "./${out}/other.js";`,
		`import { respond as third } from "./${out}/third.js";`,
		"console.log(respond('x'), other('y'), third('z'));",
	].join("\n"), "main x / other x / third x other y third z");
}
writeFile(`${dir}/values.ms`, [
	"export interface Shape { n: int32; }",
	"export type Count = int32;",
	"export struct Pair { n: int32; }",
	"export const chosen = 7;",
	"export const hidden = 8;",
	"export class Shell<T> { static count: int32 = 11; value: T; constructor(value: T) { this.value = value; } }",
	"export function answer(): int32 { return 42; }",
	"export default { n: 9 };",
].join("\n"));
writeFile(`${dir}/barrel.ms`, [
	"export { Shape as Outline, Count, Pair, chosen as cap, answer as respond, Shell } from \"./values\";",
	"export * as ns from \"./values\";",
	"export default { n: 10 };",
].join("\n"));
check("barrel.ms", "barrel", [
	"import value, { cap, respond, ns, Shell } from './barrel/barrel.js';",
	"import * as m from './barrel/barrel.js';",
	"console.log(Object.keys(m).sort().join(','), cap, respond(), value.n, ns.chosen, ns.default.n, Shell.count);",
].join("\n"), "Shell,cap,default,ns,respond 7 42 10 7 9 11");

writeFile(`${dir}/special.ms`, [
	"export function same<T>(x: T): T { return x; }",
	"export function pick(x: int32): int32 { return x + 1; }",
	"export function pick(x: string): string { return x + \"!\"; }",
	"export function tag(this n: int32): string { return \"n\"; }",
	"export const marker = 5;",
].join("\n"));
writeFile(`${dir}/transport.ms`, "export { same as identity, pick as choose, tag, marker as kept } from \"./special\";\n");
writeFile(`${dir}/consumer.ms`, [
	"import { identity, choose, tag, kept } from \"./transport\";",
	"export function result(): string { return identity(choose(6)).toString() + choose(identity(\"ok\")) + (1 as int32).tag() + kept.toString(); }",
].join("\n"));
check("consumer.ms", "transport", [
	"import { result } from './transport/consumer.js';",
	"import { kept } from './transport/transport.js';",
	"import * as m from './transport/transport.js';",
	"console.log(Object.keys(m).sort().join(','), result(), kept);",
].join("\n"), "kept 7ok!n5 5");

writeFile(`${dir}/runtimeOnly.ms`, "console.log(\"runtime-init\");\nexport function same<T>(x: T): T { return x; }\n");
writeFile(`${dir}/runtimeBarrel.ms`, "export { same as identity } from \"./runtimeOnly\";\n");
check("runtimeBarrel.ms", "runtime", [
	"import * as m from './runtime/runtimeBarrel.js';",
	"console.log('ready', Object.keys(m).length);",
].join("\n"), "runtime-init\nready 0");

writeFile(`${dir}/typesOnly.ms`, "console.log(\"types-init\");\nexport interface Shape { n: int32; }\n");
writeFile(`${dir}/typesBarrel.ms`, "export { Shape as Outline } from \"./typesOnly\";\nexport const ready = 1;\n");
check("typesBarrel.ms", "types", [
	"import { ready } from './types/typesBarrel.js';",
	"console.log(ready);",
].join("\n"), "1");

writeFile(`${dir}/star.ms`, "export * from \"./values\";\n");
check("star.ms", "star", [
	"import { chosen, hidden, answer, Shell } from './star/star.js';",
	"import * as m from './star/star.js';",
	"console.log(Object.keys(m).sort().join(','), chosen, hidden, answer(), Shell.count);",
].join("\n"), "Shell,answer,chosen,hidden 7 8 42 11");

if (failed != 0) exit(1);
console.log("GUARD-OK");
