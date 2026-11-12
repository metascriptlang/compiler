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
put(`${graph}/side.cms`, "console.log(\"side\");\n");
record("a .cms file beside a graph build.ms is a file, not a node name", "side",
	lastLine(run(graph, ["run", "--colors=off", "side.cms"])));
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

const globbed = `${root}/globbed`;
ensureDir(`${globbed}/src/nested`);
for (const name of ["src/a.txt", "src/b.txt", "src/nested/n.txt"]) put(`${globbed}/${name}`, "x\n");
put(`${globbed}/hidden.txt`, "one\n");
put(`${globbed}/build.ms`, [
	"import { systemCommand, step, glob } from \"std/build\";",
	"console.log(\"configured\");",
	"const sources = glob(\"src/*.txt\");",
	"export const found = step({ description: \"list\", inputs: [], make: (): void => { console.log(sources.map((p) => p.sub).join(\",\")); } });",
	`export const reader = systemCommand(["sh", "-c", "cat hidden.txt > \\"$1\\"; echo \\"$1: hidden.txt\\" > \\"$2\\"", "${root}"]);`,
	"reader.addOutputFileArg(\"copy.txt\");",
	"reader.addDepFileOutputArg(\"copy.d\");",
	"",
].join("\n"));
record("glob lists the files its pattern names under the calling file's directory", "src/a.txt,src/b.txt", lastLine(run(globbed, ["build", "--colors=off", "found"])));
const globListings = [run(globbed, ["build", "--colors=off", "--list"]), run(globbed, ["build", "--colors=off", "--list"])];
put(`${globbed}/src/c.txt`, "x\n");
globListings.push(run(globbed, ["build", "--colors=off", "--list"]));
record("a new file matching a glob invalidates the cached configure", "cached|cached|evaluated", globListings.map(evaluated).join("|"));
function copiedText(dir: string = globbed): string {
	const out = run(dir, ["build", "--colors=off", "reader"]);
	const copy = readFile(`${out.split(" → ").pop()}/copy.txt`);
	return `${out.includes("reused: ") ? "reused" : "ran"}:${copy.ok ? copy.value.trim() : "missing"}`;
}
const depRuns = [copiedText(), copiedText()];
put(`${globbed}/hidden.txt`, "two\n");
depRuns.push(copiedText());
record("an input a depfile names reruns its command when it changes", "ran:one|reused:one|ran:two", depRuns.join("|"));
const copied = `${root}/copied`;
ensureDir(copied);
for (const name of ["build.ms", "hidden.txt"]) {
	const text = readFile(`${globbed}/${name}`);
	put(`${copied}/${name}`, text.ok ? text.value : "");
}
const copiedRuns = [copiedText(copied)];
put(`${copied}/hidden.txt`, "three\n");
copiedRuns.push(copiedText(copied));
record("a copy of the project reuses a command's output and checks its depfile inputs in its own directory", "reused:two|ran:three", copiedRuns.join("|"));
put(`${globbed}/hidden.txt`, "one\n");
record("a tree back at an earlier state reuses the output that state produced", "reused:one", copiedText());
record("--seed keeps the build's result", "src/a.txt,src/b.txt,src/c.txt", lastLine(run(globbed, ["build", "--colors=off", "--seed=7", "found"])));

const written = `${root}/written`;
ensureDir(`${written}/gen`);
put(`${written}/seed.txt`, "seed\n");
put(`${written}/build.ms`, [
	"import { writeFiles, updateSourceFiles, systemCommand, path } from \"std/build\";",
	"const files = writeFiles();",
	"files.add(\"a.txt\", \"made\\n\");",
	"files.addCopyFile(path(\"seed.txt\"), \"sub/b.txt\");",
	"export const both = systemCommand([\"sh\", \"-c\", \"cat a.txt sub/b.txt\"]);",
	"both.setCwd(files.getDirectory());",
	"const table = both.captureStdOut();",
	"export const sync = updateSourceFiles();",
	"sync.addCopyFileToSource(table, path(\"gen/table.txt\"));",
	"sync.addBytesToSource(\"fixed\\n\", path(\"gen/fixed.txt\"));",
	"",
].join("\n"));
const syncRuns = [run(written, ["build", "--colors=off", "sync"]), run(written, ["build", "--colors=off", "sync"])].map((out: string): string => out.split("\n").filter((l: string): boolean => l.startsWith("updated")).join(","));
const table = readFile(`${written}/gen/table.txt`);
record("writeFiles gathers bytes and a copied file that a command reads", "made|seed", table.ok ? table.value.trim().split("\n").join("|") : "missing");
record("updateSourceFiles writes a changed file once and leaves it after", "updated gen/table.txt,updated gen/fixed.txt|", syncRuns.join("|"));

const initialised = `${root}/initialised`;
ensureDir(initialised);
run(initialised, ["init"]);
record("init writes a two-line graph that run builds and runs", "hello, metascript!", lastLine(run(initialised, ["run", "--colors=off"])));
run(initialised, ["build", "--colors=off"]);
record("build of an unnamed default executable writes out/<entry name>", "out/index", exists(`${initialised}/out/index`) || exists(`${initialised}/out/index.exe`) ? "out/index" : "missing");
const depLib = `${root}/deplib`;
const depApp = `${root}/depapp`;
ensureDir(`${depLib}/src`);
ensureDir(`${depApp}/src`);
put(`${depLib}/src/index.ms`, "export function greet(): string { return \"from lib\"; }\n");
put(`${depLib}/build.ms`, "import { library, path, Linkage, Optimize, Library } from \"std/build\";\nexport function lib(o: { optimize: Optimize }): Library {\n\treturn library({ linkage: Linkage.Static, entry: path(\"src/index.ms\"), optimize: o.optimize });\n}\n");
put(`${depApp}/src/main.ms`, "import { greet } from \"lib/src/index\";\nconsole.log(greet());\n");
put(`${depApp}/build.ms`, [
	"import { executable, path, project, Optimize } from \"std/build\";",
	"import { lib } from \"lib/build\";",
	"export const settings = project({ deps: { lib: \"file:../deplib\" } });",
	"export const app = executable({ entry: path(\"src/main.ms\"), link: [lib({ optimize: Optimize.Debug }), lib({ optimize: Optimize.Debug }), lib({ optimize: Optimize.ReleaseFast })] });",
	"",
].join("\n"));
const libBuilds = run(depApp, ["build", "--colors=off", "--dry-run", "app"]).split("\n").filter((line: string): boolean => line.includes("--app=staticlib"));
const libOutputs = libBuilds.map((line: string): string => line.split(" ").filter((w: string): boolean => w.startsWith("--output="))[0]);
record("a dependency's build function called twice with the same arguments builds once, and once per other arguments", "2 builds, 2 outputs",
	`${libBuilds.length} builds, ${libOutputs.filter((o: string, i: number): boolean => libOutputs.indexOf(o) == i).length} outputs`);
put(`${initialised}/build.ms`,"import { executable, systemCommand, path } from \"std/build\";\nexport default executable({ entry: path(\"src/index.ms\") });\nexport const noop = systemCommand([\"true\"]);\n");
record("an export after export default is a node too", "noop  command|default  executable", run(initialised, ["build", "--colors=off", "--list"]).split("\n").join("|"));

const checks = `${root}/checks`;
ensureDir(`${checks}/src`);
put(`${checks}/src/main.ms`, "import { argv } from \"std/process\";\nconsole.log(`app ${argv.slice(1).join(\",\")}`);\n");
put(`${checks}/build.ms`, [
	"import { executable, runArtifact, systemCommand, path, mscExe } from \"std/build\";",
	"export const app = executable({ entry: path(\"src/main.ms\") });",
	"export const self = systemCommand([\"echo\", mscExe()]);",
	"self.captureStdOut();",
	"export const touch = systemCommand([\"sh\", \"-c\", \"echo x >> runs.txt\"]);",
	`export const checked = systemCommand(["sh", "-c", "echo ${root} >> checked.txt"]);`,
	"checked.expectExitCode(0);",
	"export const failing = systemCommand([\"sh\", \"-c\", \"echo x >> failed.txt; exit 3\"]);",
	"failing.expectExitCode(0);",
	"export const three = systemCommand([\"sh\", \"-c\", \"exit 3\"]);",
	"three.expectExitCode(3);",
	"export const shown = runArtifact(app, [\"second\"]);",
	"shown.captureStdOut();",
	"export const named = systemCommand([\"echo\"]);",
	"named.addPrefixedArtifactArg(\"--msc=\", app);",
	"named.captureStdOut();",
	"export const echoed = systemCommand([\"echo\", \"args\"]);",
	"",
].join("\n"));

function lines(path: string): string {
	const text = readFile(path);
	return text.ok ? `${text.value.trim().split("\n").length}` : "0";
}

function storedStdout(out: string): string {
	const text = readFile(`${out.split(" → ").pop()}/stdout`);
	return text.ok ? text.value.trim() : `unreadable ${out}`;
}

run(checks, ["build", "--colors=off", "touch"]);
run(checks, ["build", "--colors=off", "touch"]);
record("a command with no output and no check runs every time", "2", lines(`${checks}/runs.txt`));
run(checks, ["build", "--colors=off", "checked"]);
const checkedAgain = run(checks, ["build", "--colors=off", "checked"]);
record("a checked command that passed is reused", "1|reused: checked", `${lines(`${checks}/checked.txt`)}|${checkedAgain.split("\n")[0]}`);
const failedOnce = run(checks, ["build", "--colors=off", "failing"]);
run(checks, ["build", "--colors=off", "failing"]);
record("a checked command that failed runs again", "2|exited with 3, expected 0", `${lines(`${checks}/failed.txt`)}|${failedOnce.includes("exited with 3, expected 0") ? "exited with 3, expected 0" : failedOnce}`);
record("expectExitCode accepts the code it names", "passed", passes(run(checks, ["build", "--colors=off", "three"])));
record("runArtifact runs the built executable and can capture its stdout", "app second", storedStdout(run(checks, ["build", "--colors=off", "shown"])));
const namedOut = storedStdout(run(checks, ["build", "--colors=off", "named"]));
record("addPrefixedArtifactArg passes the built executable's path", "--msc=/tmp/…/checks/out/app", namedOut.startsWith("--msc=/tmp/") && namedOut.endsWith("/checks/out/app") ? "--msc=/tmp/…/checks/out/app" : namedOut);
record("mscExe() is the msc that runs the build", compiler, storedStdout(run(checks, ["build", "--colors=off", "self"])));
record("arguments after -- reach the command node msc build names", "args a b", lastLine(run(checks, ["build", "--colors=off", "echoed", "--", "a", "b"])));

const staged = `${root}/staged`;
ensureDir(`${staged}/src`);
put(`${staged}/src/main.ms`, "console.log(1);\n");
put(`${staged}/build.ms`, [
	"import { executable, path, LtoMode } from \"std/build\";",
	"export const stage1 = executable({ entry: path(\"src/main.ms\"), lto: LtoMode.None });",
	"export const stage2 = executable({ entry: path(\"src/main.ms\"), compiler: stage1 });",
	"",
].join("\n"));
const stagedPlan = run(staged, ["build", "--colors=off", "--dry-run", "stage2"]).split("\n");
record("lto: LtoMode.None builds with --lto=off", "--lto=off", stagedPlan[0].split(" ").filter((w: string): boolean => w.startsWith("--lto")).join(" "));
record("an executable with a compiler is built by that artifact", `${staged}/out/stage1`, stagedPlan.length > 1 ? stagedPlan[1].split(" ")[0] : stagedPlan.join("|"));

const bounded = `${root}/bounded`;
ensureDir(bounded);
put(`${bounded}/build.ms`, [
	"import { systemCommand, step, Command } from \"std/build\";",
	"function exclusive(name: string, maxRss: number): Command {",
	"\tconst c = systemCommand([\"sh\", \"-c\", `date +%s%N > ${name}.start; sleep 1; date +%s%N > ${name}.end`]);",
	"\tc.maxRss = maxRss;",
	"\treturn c;",
	"}",
	"export const both = step({ description: \"both\", inputs: [exclusive(\"a\", 600e6), exclusive(\"b\", 600e6)], make: (): void => {} });",
	"export const huge = exclusive(\"huge\", 1e18);",
	"export const greedy = systemCommand([\"sh\", \"-c\", \"held=$(head -c 100000000 /dev/zero | tr \\\\\\\\0 a); echo ${#held}\"]);",
	"greedy.maxRss = 20e6;",
	"export const crashed = systemCommand([\"sh\", \"-c\", \"kill -SEGV $$\"]);",
	`export const crashedChecked = systemCommand([\"sh\", \"-c\", \"kill -SEGV $$; : ${bounded}\"]);`,
	"crashedChecked.expectExitCode(0);",
	"",
].join("\n"));
function overlap(dir: string, args: string[]): string {
	const out = run(dir, args);
	if (out.startsWith("exit ")) return out;
	const at = (file: string): number => {
		const text = readFile(`${dir}/${file}`);
		return text.ok ? parseFloat(text.value) : NaN;
	};
	const a = [at("a.start"), at("a.end")];
	const b = [at("b.start"), at("b.end")];
	return a[0] < b[1] && b[0] < a[1] ? "overlapped" : "one after the other";
}
record("two nodes whose maxRss together exceed --maxrss never run at once", "one after the other", overlap(bounded, ["build", "--colors=off", "-j2", "--maxrss=1000M", "both"]));
record("two nodes whose maxRss fit --maxrss run at once", "overlapped", overlap(bounded, ["build", "--colors=off", "-j2", "--maxrss=1200M", "both"]));
record("a node above --maxrss stops the build before anything runs", "huge: declares maxRss 953674316406 MiB, above the 1000 bytes this build may use (--maxrss)",
	errorLine(run(bounded, ["build", "--colors=off", "--maxrss=1000", "huge"])));
const greedy = errorLine(run(bounded, ["build", "--colors=off", "greedy"]));
record("a command that peaks above its maxRss fails the build", "peaked above maxRss of 19 MiB", greedy.includes(" peaked at ") && greedy.endsWith("above its declared maxRss of 19 MiB") ? "peaked above maxRss of 19 MiB" : greedy);
const aboveTotal = errorLine(run(bounded, ["build", "--colors=off", "huge"]));
record("without --maxrss the bound is the machine's memory", "MiB this build may use", aboveTotal.endsWith("MiB this build may use (--maxrss)") ? "MiB this build may use" : aboveTotal);
for (const name of ["crashed", "crashedChecked"]) {
	const crash = errorLine(run(bounded, ["build", "--colors=off", name]));
	record(`a ${name == "crashed" ? "" : "checked "}command killed by a signal fails the build`, "killed by signal 11", crash.includes("was killed by signal 11") ? "killed by signal 11" : crash);
}

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
