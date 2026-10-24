// Project-config boundary test: every command takes the project's build.ms from the project root of the
// entry file, so it must run the real `msc` over a project whose build.ms is not in the working directory.
// Run: msc run --target=raiser src/test/projectConfigCommands.ms <msc>
import { argv, cwd, execFileCapture, exit } from "std/process";
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

let failures = 0;
console.log(`root ${root}`);
for (const r of results) {
	const pass = r.expected == r.actual;
	if (!pass) failures = failures + 1;
	console.log(`${pass ? "pass" : "FAIL"}  ${r.name}  expected=${r.expected} actual=${r.actual}`);
}
if (failures == 0) removeAll(root);
exit(failures == 0 ? 0 : 1);
