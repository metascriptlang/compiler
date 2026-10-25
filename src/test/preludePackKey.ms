// The prelude pack is keyed by what its content is read from: the msc binary and the std tree.
// It runs a real `msc check` against a private install whose runtime/ and std/ it edits.
// Run: msc run --target=raiser src/test/preludePackKey.ms <msc>
import { argv, cwd, env, execFileCapture, exit } from "std/process";
import { appendFile, ensureDir, exists, readDir, readFile, removeAll, writeFile } from "std/fs";

interface CaseResult {
	name: string;
	expected: string;
	actual: string;
}

const params = argv.slice(1).filter((a: string): boolean => !a.startsWith("--"));
const compiler = params.length > 0 && params[0].startsWith("/") ? params[0] : `${cwd()}/${params.length > 0 ? params[0] : "msc"}`;
const repo = cwd();

function makeRoot(): string {
	let n = performance.now() as int64;
	while (exists(`/tmp/msc-prelude-key-${n}`)) n = n + 1;
	const dir = `/tmp/msc-prelude-key-${n}`;
	ensureDir(dir);
	return dir;
}

const root = makeRoot();
const install = `${root}/install`;
const home = `${root}/home`;
const project = `${root}/project`;
const results: CaseResult[] = [];

function need(ok: boolean, what: string): void {
	if (ok) return;
	console.log(`prelude-key: setup step failed: ${what} (root ${root})`);
	exit(1);
}

function copy(from: string, to: string): void {
	need(execFileCapture("/bin/cp", ["-R", from, to], root).ok, `copy ${from}`);
}

ensureDir(install);
ensureDir(home);
ensureDir(project);
copy(compiler, `${install}/msc`);
copy(`${repo}/std`, `${install}/std`);
copy(`${repo}/runtime`, `${install}/runtime`);
need(writeFile(`${project}/main.ms`, "console.log(JSON.stringify([1]));\n").ok, "write main.ms");

function check(): void {
	const saved = env.get("HOME");
	env.set("HOME", home);
	const r = execFileCapture(`${install}/msc`, ["check", "main.ms", "--colors=off"], project);
	env.set("HOME", saved);
	need(r.ok, `check: ${r.ok ? "" : r.error.output + r.error.errorOutput}`);
}

// Each pack file with the stamp line it was written under.
function packs(): string {
	const base = `${home}/.metascript/cache/prelude`;
	const rows: string[] = [];
	for (const format of readDir(base)) {
		if (format.startsWith(".")) continue;
		for (const name of readDir(`${base}/${format}`)) {
			if (!name.endsWith(".pk")) continue;
			const text = readFile(`${base}/${format}/${name}`);
			rows.push(`${format}/${name} ${text.ok ? text.value.split("\n")[1] : "unreadable"}`);
		}
	}
	rows.sort();
	return rows.join(" | ");
}

function sameOrChanged(before: string, after: string): string {
	return before == after ? "same" : "changed";
}

check();
const cold = packs();
results.push({ name: "a cold check writes a prelude pack", expected: "written", actual: cold != "" ? "written" : "none" });

need(appendFile(`${install}/runtime/core/string.h`, "\n/* prelude-key probe */\n").ok, "append probe");
check();
const afterRuntime = packs();
results.push({ name: "a runtime header edit keeps the pack key and stamp", expected: "same", actual: sameOrChanged(cold, afterRuntime) });

need(appendFile(`${install}/std/core/system/index.ms`, "\n// prelude-key probe\n").ok, "append probe");
check();
results.push({ name: "an edit of a std module the prelude reads changes the pack", expected: "changed", actual: sameOrChanged(afterRuntime, packs()) });

let failures = 0;
console.log(`root ${root}`);
for (const r of results) {
	const pass = r.expected == r.actual;
	if (!pass) failures = failures + 1;
	console.log(`${pass ? "pass" : "FAIL"}  ${r.name}  expected=${r.expected} actual=${r.actual}`);
}
if (failures == 0) removeAll(root);
exit(failures == 0 ? 0 : 1);
