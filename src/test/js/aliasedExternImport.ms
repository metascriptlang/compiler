// An importer's local alias of an @import-backed extern stays the importer's binding: the
// import and the defining module's export name the declared extern. Built and run with the
// compiler under test, $MSC else ./msc.

import { cwd, env, execFileCapture } from "std/process";
import { writeFile, ensureDir } from "std/fs";

function compilerPath(): string {
	const named = env.get("MSC");
	if (named != "") return named.startsWith("/") ? named : `${cwd()}/${named}`;
	return `${cwd()}/msc`;
}

function sandbox(name: string, source: string): string {
	const dir = `${cwd()}/out/aliasedExternImport-${name}-${performance.now().toString()}`;
	ensureDir(dir);
	if (!writeFile(`${dir}/main.ms`, source).ok) throw new Error("cannot write " + dir);
	return dir;
}

function msc(dir: string, args: string[]): string {
	const r = execFileCapture(compilerPath(), args, dir);
	return r.ok ? r.value : "FAILED " + r.error.output + r.error.errorOutput;
}

const aliased = `import { cwd as osCwd } from "std/process";
test "aliased extern" { assert osCwd().length > 0; }
`;

const single = `import { cwd as osCwd } from "std/process";
console.log(\`single \${osCwd().length > 0}\`);
`;

const both = `import { cwd as osCwd, cwd } from "std/process";
console.log(\`both \${osCwd() == cwd()}\`);
`;

const second = `import { exit as quit, cwd as where } from "std/process";
console.log(\`second \${where().length > 0}\`);
quit(0);
`;

test "msc test --target=js runs a test that aliases an extern import" {
	const out = msc(sandbox("test", aliased), ["test", "main.ms", "--tests-in-dir", "--target=js"]);
	assert !out.startsWith("FAILED"), out;
}

test "msc run --target=js runs a program that aliases an extern import" {
	const out = msc(sandbox("run", single), ["run", "--target=js", "main.ms"]);
	assert out.trim() == "single true", out;
}

test "an aliased and an unaliased importer of one extern share the program" {
	const out = msc(sandbox("both", both), ["run", "--target=js", "main.ms"]);
	assert out.trim() == "both true", out;
}

test "a second aliased extern keeps its own binding" {
	const out = msc(sandbox("second", second), ["run", "--target=js", "main.ms"]);
	assert out.trim() == "second true", out;
}

test "the single-file JS bundle runs an aliased extern" {
	const dir = sandbox("bundle", both);
	const built = msc(dir, ["build", "--target=js", `--output=${dir}/bundle.js`, "main.ms"]);
	assert !built.startsWith("FAILED"), built;
	const r = execFileCapture("node", [`${dir}/bundle.js`]);
	assert r.ok && r.value.trim() == "both true", r.ok ? r.value : r.error.errorOutput;
}

test "the split ESM tree loads in node with an aliased extern" {
	const dir = sandbox("split", second);
	const built = msc(dir, ["build", "--target=js", "--split", `--output=${dir}/tree`, "main.ms"]);
	assert !built.startsWith("FAILED"), built;
	const entry = "const t = process.argv[1], m = require(t + '/_manifest.json').modules.find((x) => x.source.endsWith('/main.ms')); import(t + '/' + m.out);";
	const r = execFileCapture("node", ["-e", entry, `${dir}/tree`]);
	assert r.ok && r.value.trim() == "second true", r.ok ? r.value : r.error.errorOutput;
}

test "the C target runs an aliased extern" {
	const out = msc(sandbox("c", both), ["run", "main.ms"]);
	assert out.trim() == "both true", out;
}
