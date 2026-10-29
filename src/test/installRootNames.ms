// Pipeline boundary test like nativeBuildBoundary.ms: it copies the compiler and its std to two install roots, which no in-process c/ or js/ test can do.
import { argv, cwd, execFileCapture, exit, platform } from "std/process";
import { ensureDir, exists, readDir, readFile, removeAll, writeFile } from "std/fs";
import { dirname } from "std/fs/path";

function absolute(path: string): string {
	if (path.startsWith("/") || (path.length > 1 && path.charAt(1) == ":")) return path;
	return `${cwd()}/${path}`;
}

const params = argv.slice(1).filter((a: string): boolean => !a.startsWith("--"));
const compiler = absolute(params.length > 0 ? params[0] : "msc");
const support = exists(`${dirname(compiler)}/std`) ? dirname(compiler) : dirname(dirname(compiler));

if (platform == "windows") {
	console.log("skip installRootNames: the install copies use POSIX cp");
	exit(0);
}

function makeRoot(): string {
	let n = performance.now() as int64;
	while (exists(`/tmp/msc-install-roots-${n}`)) n = n + 1;
	const dir = `/tmp/msc-install-roots-${n}`;
	ensureDir(dir);
	return dir;
}

const root = makeRoot();

function need(ok: boolean, what: string): void {
	if (ok) return;
	console.log(`installRootNames: setup step failed: ${what} (root ${root})`);
	exit(1);
}

function run(dir: string, exe: string, args: string[]): void {
	const r = execFileCapture(exe, args, dir);
	need(r.ok, `${exe} ${args.join(" ")} in ${dir}: ${r.ok ? "" : r.error.output + r.error.errorOutput + r.error.message}`);
}

const LIB = [
	"export class Box<T> {",
	"\titem: T;",
	"\tconstructor(item: T) { this.item = item; }",
	"\tget(): T { return this.item; }",
	"}",
	"export function first<T>(xs: T[]): T { return xs[0]; }",
	"",
].join("\n");

const MAIN = [
	"import { HashMap } from \"std/core/struct\";",
	"import { Box, first } from \"./lib\";",
	"class Node { v: number = 1; }",
	"const nodes: Node[] = [new Node(), new Node()];",
	"const popped = nodes.pop()!;",
	"const boxed = new Box<Node>(new Node());",
	"const head = first<Node>(nodes);",
	"const byName = new HashMap<string, Node>();",
	"byName.set(\"a\", head);",
	"console.log(`${popped.v} ${boxed.get().v} ${head.v} ${byName.size}`);",
	"",
].join("\n");

function install(at: string): string {
	ensureDir(at);
	run(at, "cp", [compiler, `${at}/msc`]);
	run(at, "cp", ["-R", `${support}/std`, `${support}/runtime`, at]);
	if (exists(`${support}/vendor`)) run(at, "ln", ["-s", `${support}/vendor`, `${at}/vendor`]);
	const app = `${at}/work/app`;
	ensureDir(app);
	need(writeFile(`${app}/lib.ms`, LIB).ok, "write lib.ms");
	need(writeFile(`${app}/main.ms`, MAIN).ok, "write main.ms");
	run(app, `${at}/msc`, ["build", "main.ms", "--emit=c", "--trimpath"]);
	run(app, `${at}/msc`, ["build", "main.ms", "--target=js", "--output=out.js"]);
	return app;
}

function text(path: string): string {
	const r = readFile(path);
	need(r.ok, `read ${path}`);
	return r.ok ? r.value : "";
}

const near = install(`${root}/a`);
const far = install(`${root}/a-much-longer-install/inner`);

let failures = 0;
function check(name: string, ok: boolean): void {
	if (!ok) failures = failures + 1;
	console.log(`${ok ? "pass" : "FAIL"}  ${name}`);
}

function cFiles(app: string): string[] {
	const found = readDir(`${app}/out/debug`).filter((f: string): boolean => f.endsWith(".c"));
	found.sort();
	return found;
}

const files = cFiles(near);
check("both install roots emit the same C modules", files.join(",") == cFiles(far).join(","));
const differing: string[] = [];
for (const f of files) {
	if (text(`${near}/out/debug/${f}`) != text(`${far}/out/debug/${f}`)) differing.push(f);
}
check(`one program emits byte-identical C from two install roots (differing: ${differing.join(",")})`, files.length > 0 && differing.length == 0);
const mainC = files.filter((f: string): boolean => f.contains("mainOms")).map((f: string): string => text(`${near}/out/debug/${f}`)).join("");
check("the C names a std generic instance, a user generic class instance and a user generic routine instance", mainC.contains("HashMap_") && mainC.contains("Box_") && mainC.contains("first_"));
const nearJs = text(`${near}/out.js`);
check("one program emits byte-identical JS from two install roots", nearJs == text(`${far}/out.js`));
check("the JS names a std generic instance, a user generic class instance and a user generic routine instance", nearJs.contains("pop_") && nearJs.contains("Box_") && nearJs.contains("first_"));

console.log(`root ${root}`);
if (failures == 0) removeAll(root);
exit(failures == 0 ? 0 : 1);
