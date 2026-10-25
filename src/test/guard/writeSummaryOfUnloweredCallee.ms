// A module whose call reaches a routine of a module not yet lowered in the build (an import
// cycle) summarizes that routine's writes without needing hooks that module has not lifted yet.
//
// WHY A SUBPROCESS: the observable is the exit and output of a two-module build. The compiler
// under test is $MSC, else `./msc`.
//
// RED PRE-FIX: every cell failed with "type-bound op destroy|object:Layer__aOms is used before
// it was lifted". GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardWriteSummaryUnlowered`;

const moduleA = `import { outer } from "./b";

enum Wrap { A, B }

struct Layer { wrap: Wrap; size: int32; inner: string; }

function wrapOne(layer: Layer, inner: string): string {
	return match (layer.wrap) {
		Wrap.A => inner + "[]",
		Wrap.B => "B<" + inner + ">",
	};
}

export function resolve(text: string): string {
	const layers: Layer[] = [];
	layers.push({ wrap: Wrap.A, size: 1, inner: text });
	layers.push({ wrap: Wrap.B, size: 2, inner: text + "x" });
	let t = text;
	for (let i = layers.length - 1; i >= 0; i -= 1) t = wrapOne(layers[i], t);
	return t;
}

console.log(outer("q"));
`;

const moduleB = `import { resolve } from "./a";

export function outer(text: string): string {
	return "<" + resolve(text) + ">";
}
`;

let failed = 0;

function run(label: string, jobs: string[]): void {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	writeFile(`${cell}/a.ms`, moduleA);
	writeFile(`${cell}/b.ms`, moduleB);
	const args = ["build"];
	for (const j of jobs) args.push(j);
	args.push("a.ms");
	args.push("--output=a");
	const built = execFileResult(msc, args, cell);
	if (built.exitCode != 0) {
		console.log(`GUARD-FAIL ${label}: msc build exited ${built.exitCode.toString()}\n${built.output}${built.errorOutput}`);
		failed = failed + 1;
		return;
	}
	const ran = execFileResult(`${cell}/a`, [], cell);
	if (ran.exitCode != 0 || ran.output.trim() != "<B<q>[]>") {
		console.log(`GUARD-FAIL ${label}: the program exited ${ran.exitCode.toString()} and printed '${ran.output.trim()}', expected '<B<q>[]>'`);
		failed = failed + 1;
	}
}

removeAll(dir);
ensureDir(dir);
run("parallel", []);
run("serial", ["--emit-jobs=1"]);
removeAll(dir);

if (failed > 0) exit(1);
console.log("GUARD-OK");
