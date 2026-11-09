// Project-config boundary test: every command takes the project's build.ms from the project root of the
// entry file, so it must run the real `msc` over a project whose build.ms is not in the working directory.
// Run: msc run --target=raiser src/test/projectConfigCommands.ms <msc>
import { argv, cwd, execFileCapture, exit, platform } from "std/process";
import { ensureDir, exists, readFile, removeAll, writeFile } from "std/fs";

interface CaseResult {
	name: string;
	expected: string;
	actual: string;
}

const params = argv.slice(1).filter((a: string): boolean => !a.startsWith("--"));
const compiler = params.length > 0 && (params[0].startsWith("/") || params[0].charAt(1) == ":") ? params[0] : `${cwd()}/${params.length > 0 ? params[0] : "msc"}`;

function makeRoot(): string {
	let n = performance.now() as int64;
	while (exists(`/tmp/msc-project-config-${n}`)) n = n + 1;
	const dir = `/tmp/msc-project-config-${n}`;
	ensureDir(dir);
	return dir;
}

const root = makeRoot();
const results: CaseResult[] = [];

function put(path: string, content: string): void {
	if (writeFile(path, content).ok) return;
	console.log(`project-config: cannot write ${path}`);
	exit(1);
}

function project(name: string, config: string): string {
	const dir = `${root}/${name}`;
	ensureDir(`${dir}/src`);
	put(`${dir}/build.ms`, `import { BuildConfig } from "std/build";\nconst config: BuildConfig = ${config};\nexport default config;\n`);
	return dir;
}

function run(cwdDir: string, args: string[]): string {
	const r = execFileCapture(compiler, args, cwdDir);
	if (r.ok) return r.value.trim();
	return `exit ${r.error.exitCode}: ${(r.error.output + r.error.errorOutput).trim()}`;
}

function record(name: string, expected: string, actual: string): void {
	results.push({ name, expected, actual });
}

ensureDir(`${root}/lib`);
put(`${root}/lib/index.ms`, "export function hello(): string { return \"hi\"; }\n");
put(`${root}/lib/build.ms`, "const config = {};\nexport default config;\n");

const aliased = project("aliased", "{ entry: \"main.ms\", resolve: { alias: { \"@lib\": \"../lib\" } } }");
put(`${aliased}/main.ms`, "import { hello } from \"@lib/index\";\nconsole.log(hello());\n");

const depended = project("depended", "{ entry: \"main.ms\", deps: { \"mylib\": \"file:../lib\" } }");
put(`${depended}/main.ms`, "import { hello } from \"mylib\";\nconsole.log(hello());\n");

record("check takes resolve.alias from build.ms", "OK", run(aliased, ["check", "main.ms", "--colors=off"]).split(" ")[0]);
record("run --target=raiser takes resolve.alias from build.ms", "hi", run(aliased, ["run", "--target=raiser", "main.ms"]));
record("run --target=raiser takes the alias of the entry's project from another cwd", "hi", run(root, ["run", "--target=raiser", "aliased/main.ms"]));
record("run --target=raiser takes deps from build.ms", "hi", run(depended, ["run", "--target=raiser", "main.ms"]));

function lastLine(out: string): string {
	return out.startsWith("exit ") ? out : out.split("\n").pop();
}

function passes(out: string): string {
	return out.startsWith("exit ") ? out : "passed";
}

const TEST_OF_HELLO = "test \"the imported package answers\" { assert hello() == \"hi\"; }\n";
put(`${depended}/check.ms`, `import { hello } from "mylib";\n${TEST_OF_HELLO}`);
put(`${aliased}/check.ms`, `import { hello } from "@lib/index";\n${TEST_OF_HELLO}`);

record("run takes deps from build.ms", "hi", lastLine(run(depended, ["run", "main.ms"])));
record("run --target=js takes deps from build.ms", "hi", lastLine(run(depended, ["run", "--target=js", "main.ms"])));
record("build --target=js takes deps from build.ms", "passed", passes(run(depended, ["build", "--target=js", "main.ms"])));
record("test takes deps from build.ms", "passed", passes(run(depended, ["test", "check.ms"])));
record("test --target=js takes deps from build.ms", "passed", passes(run(depended, ["test", "--target=js", "check.ms"])));
record("run takes resolve.alias from build.ms", "hi", lastLine(run(aliased, ["run", "main.ms"])));
record("run --target=js takes resolve.alias from build.ms", "hi", lastLine(run(aliased, ["run", "--target=js", "main.ms"])));
record("test takes resolve.alias from build.ms", "passed", passes(run(aliased, ["test", "check.ms"])));

const UNFORMATTED = "function f(): int32 {\nconst a = 1;\nreturn a;\n}\n";
const formatted = project("formatted", "{ entry: \"a.ms\", fmt: { useTabs: false, tabWidth: 3 } }");

function indentAfterFmt(cwdDir: string, file: string): string {
	put(`${formatted}/a.ms`, UNFORMATTED);
	run(cwdDir, ["fmt", file, "--colors=off"]);
	const r = readFile(`${formatted}/a.ms`);
	return r.ok ? r.value.split("\n")[1] : "unreadable";
}

record("fmt takes fmt from the project's build.ms in the working directory", "   const a = 1;", indentAfterFmt(formatted, "a.ms"));
record("fmt takes fmt from the file's project when the working directory is elsewhere", "   const a = 1;", indentAfterFmt(root, "formatted/a.ms"));

function checkThroughLinkedDir(): void {
	if (platform == "win32") return;
	const dir = `${root}/linked`;
	ensureDir(`${dir}/libreal/sub`);
	ensureDir(`${dir}/app`);
	put(`${dir}/libreal/sub/types.ms`, "export struct P { x: int32; }\n");
	put(`${dir}/libreal/sub/x.h`, "int linkedValue(void);\n");
	if (!execFileCapture("ln", ["-s", `${dir}/libreal`, `${dir}/lib`], dir).ok) {
		console.log(`project-config: cannot link ${dir}/lib`);
		exit(1);
	}
	put(`${dir}/app/one.ms`, "export const one: int32 = 1;\n");
	put(`${dir}/app/viaModule.ms`, "import { P } from \"../lib/sub/types\";\nexport const z: int32 = 0;\n");
	put(`${dir}/app/viaHeader.ms`, "import { linkedValue } from \"../lib/sub/x.h\";\nexport const z: int32 = 0;\n");
	for (const via of ["viaModule", "viaHeader"]) {
		put(`${dir}/app/${via}Main.ms`, `import { one } from "./one";\nimport * as linked from "./${via}";\nconsole.log(one);\n`);
		record(`check reaches a ${via == "viaModule" ? "module" : "header"} through a linked directory after another import`, "OK", run(`${dir}/app`, ["check", `${via}Main.ms`, "--colors=off"]).split(" ")[0]);
	}
}
checkThroughLinkedDir();

const targeted = project("targeted", "{ entry: \"main.ms\", cc: { targets: { \"linux-arm64\": { entry: \"cross.ms\" } } } }");
put(`${targeted}/main.ms`, "console.log(\"main\");\n");
put(`${targeted}/cross.ms`, "console.log(\"cross\");\n");
run(targeted, ["build", "--os=linux", "--cpu=arm64", "--emit=c"]);
record("build takes the target's cc entry over the project entry", "cross", exists(`${targeted}/out/debug/crossOms.c`) ? "cross" : (exists(`${targeted}/out/debug/mainOms.c`) ? "main" : "neither"));

const unread = project("unread", "{ entry: \"main.ms\", fmt: { printwidth: 40 } }");
put(`${unread}/main.ms`, "console.log(\"unread\");\n");
record("a build.ms field msc does not read stops every command", "fmt.printwidth: msc does not read this field",
	run(unread, ["check", "main.ms", "--colors=off"]).split("build.ms: ").pop().split(";")[0]);

const owning = project("owning", "{ package: { name: \"owning\", version: \"0.1.0\", bin: { hello: \"hello.ms\" } } }");
put(`${owning}/hello.ms`, "console.log(\"own command\");\n");
record("x runs a command the project itself declares", "own command", lastLine(run(owning, ["x", "hello"])));

const graph = `${root}/graph`;
ensureDir(`${graph}/src`);
ensureDir(`${graph}/tools`);
put(`${graph}/src/main.ms`, "import { argv } from \"std/process\";\nconsole.log(`app ${argv.slice(1).join(\",\")}`);\n");
put(`${graph}/tools/table.txt`, `table of ${root}\n`);
put(`${graph}/tools/gen.ms`, "import { Command, systemCommand, path } from \"std/build\";\nexport function upper(): Command {\n\tconst c = systemCommand([\"cat\"]);\n\tc.addFileArg(path(\"table.txt\"));\n\tc.captureStdOut();\n\treturn c;\n}\n");
put(`${graph}/build.ms`, [
	"import { executable, runArtifact, step, path } from \"std/build\";",
	"import { writeFile } from \"std/fs\";",
	"import { upper as makeUpper } from \"./tools/gen\";",
	"export const app = executable({ entry: path(\"./src/main.ms\") });",
	"export const run = runArtifact(app, [\"first\"]);",
	"export const upper = makeUpper();",
	`export const stamp = step({ description: "write a stamp", inputs: [app], make: (): void => { writeFile("${graph}/stamp.txt", "stamped"); } });`,
	"export const bad = step({ description: \"fail\", inputs: [], make: (): void => { throw new Error(\"gate failed: 2 tests red\"); } });",
	"export default app;",
	"",
].join("\n"));

function errorLine(out: string): string {
	return out.split("\n").filter((l: string): boolean => l.includes("error")).join("|").split("error: ").pop();
}

record("build --list names the exported nodes and the default", "app (default)|run|upper|stamp|bad",
	run(graph, ["build", "--colors=off", "--list"]).split("\n").map((l: string): string => l.split("  ")[0]).join("|"));
record("build of a run node builds the executable and runs it with its args", "app first", lastLine(run(graph, ["build", "--colors=off", "run"])));
record("run of an executable node passes the arguments after --", "app x,y", lastLine(run(graph, ["run", "--colors=off", "app", "--", "x", "y"])));
const firstUpper = run(graph, ["build", "--colors=off", "upper"]);
const storedAt = firstUpper.split(" → ").pop();
const stored = readFile(`${storedAt}/stdout`);
record("a command input given by path() resolves against the file that calls path()", `table of ${root}`, stored.ok ? stored.value.trim() : `unreadable ${firstUpper}`);
record("a command with unchanged inputs is reused from the store", "reused: upper", run(graph, ["build", "--colors=off", "upper"]).split("\n")[0]);
run(graph, ["build", "--colors=off", "stamp"]);
const stamp = readFile(`${graph}/stamp.txt`);
record("a step's make runs with host rights after configure", "stamped", stamp.ok ? stamp.value : "missing");
record("a step that throws fails the build with its message", "bad: unhandled exception: gate failed: 2 tests red", errorLine(run(graph, ["build", "--colors=off", "bad"])));
record("a missing node names the exported ones", "build.ms exports no node 'nope'; it exports app, run, upper, stamp, bad", errorLine(run(graph, ["build", "--colors=off", "nope"])));

const optioned = `${root}/optioned`;
ensureDir(optioned);
const OPTIONED_BUILD = [
	"import { step, option, standardOptimizeOption } from \"std/build\";",
	"console.log(\"configured\");",
	"const greeting = option(\"greeting\", \"what the step prints\") ?? \"hello\";",
	"const optimize = standardOptimizeOption();",
	"export const say = step({ description: \"say\", inputs: [], make: (): void => { console.log(`${greeting} ${optimize}`); } });",
	"export default say;",
	"",
].join("\n");
put(`${optioned}/build.ms`, OPTIONED_BUILD);
record("-Dname=value reaches option()", "hi Debug", lastLine(run(optioned, ["build", "--colors=off", "-Dgreeting=hi", "say"])));
record("--release is the standard optimize option", "hello ReleaseSafe", lastLine(run(optioned, ["build", "--colors=off", "--release", "say"])));
record("an option build.ms does not declare stops the build", "the command line gives the option 'nope', which build.ms does not declare; it declares greeting, optimize",
	errorLine(run(optioned, ["build", "--colors=off", "-Dnope=1", "say"])).split("build.ms: ").pop());
const evaluated = (out: string): string => out.includes("configured") ? "evaluated" : "cached";
const listings = [run(optioned, ["build", "--colors=off", "--list"]), run(optioned, ["build", "--colors=off", "--list"])];
put(`${optioned}/build.ms`, `${OPTIONED_BUILD}// edited\n`);
listings.push(run(optioned, ["build", "--colors=off", "--list"]));
record("configure is cached until build.ms changes", "evaluated|cached|evaluated", listings.map(evaluated).join("|"));
record("a step runs from a cached graph", "hello Debug", lastLine(run(optioned, ["build", "--colors=off", "say"])));

const hostile = `${root}/hostile`;
ensureDir(`${hostile}/src`);
put(`${hostile}/src/main.ms`, "console.log(1);\n");
put(`${hostile}/build.ms`, `import { executable, path } from "std/build";\nimport { writeFile } from "std/fs";\nwriteFile("${hostile}/leak.txt", "x");\nexport default executable({ entry: path("src/main.ms") });\n`);
const refused = run(hostile, ["build", "--colors=off"]);
record("configure refuses a host call that writes", "refused, nothing written",
	refused.includes("Restricted compile-time code") && refused.includes("std/fs.writeFile") && !exists(`${hostile}/leak.txt`) ? "refused, nothing written" : refused);

let failures = 0;
console.log(`root ${root}`);
for (const r of results) {
	const pass = r.expected == r.actual;
	if (!pass) failures = failures + 1;
	console.log(`${pass ? "pass" : "FAIL"}  ${r.name}  expected=${r.expected} actual=${r.actual}`);
}
if (failures == 0) removeAll(root);
exit(failures == 0 ? 0 : 1);
