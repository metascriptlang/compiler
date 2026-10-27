// A kept build session re-emits only the modules an edit reaches, yet a generic instance two
// importers mint must still be defined by exactly one of them, and every warm build must emit the
// bytes a cold build of the same sources emits. Each test replays edits to one importer through
// `--hcr --watch-replay` (the one driver of a kept session) with the compiler under test ($MSC,
// else `./msc`), then rebuilds each state cold.
import { execFileResult, cwd, env } from "std/process";
import { writeFile, ensureDir, removeAll, readFile, readDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

const FN_LIB = "export function findIt<T>(x: T): T { return x; }\n";
const CLASS_LIB = "export class Wrap<T> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n\tget(): T { return this.v; }\n}\n";
const BOX = "export class Box { n: int32 = 3; }\n";
const APP = "import { m } from \"./m\";\nimport { n } from \"./n\";\nconsole.log(m(), n());\n";

const FN_M = "import { findIt } from \"./lib\";\nimport { Box } from \"./box\";\nexport function m(): int32 { return findIt<Box>(new Box()).n; }\n";
const FN_N_BOX = (k: int32): string => `import { findIt } from "./lib";\nimport { Box } from "./box";\nexport function n(): int32 { return findIt<Box>(new Box()).n + ${k}; }\n`;
const FN_N_INT = "import { findIt } from \"./lib\";\nexport function n(): int32 { return findIt<int32>(4); }\n";

const CLASS_M = "import { Wrap } from \"./lib\";\nimport { Box } from \"./box\";\nexport function m(): int32 { return new Wrap<Box>(new Box()).get().n; }\n";
const CLASS_N_BOX = (k: int32): string => `import { Wrap } from "./lib";\nimport { Box } from "./box";\nexport function n(): int32 { return new Wrap<Box>(new Box()).get().n + ${k}; }\n`;
const CLASS_N_INT = "import { Wrap } from \"./lib\";\nexport function n(): int32 { return new Wrap<int32>(4).get(); }\n";

function cFiles(dir: string): string[] {
	const names: string[] = [];
	for (const e of readDir(dir)) {
		if (e.endsWith(".c")) names.push(e);
	}
	names.sort();
	return names;
}

function text(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : `UNREADABLE ${path}`;
}

function definitions(files: string[], dir: string, stem: string): number {
	let count = 0;
	for (const f of files) {
		for (const line of text(`${dir}/${f}`).split("\n")) {
			if (line.contains(stem) && line.contains("Box") && line.endsWith(") {")) count += 1;
		}
	}
	return count;
}

// Builds `lib`, `box`, `m` and an `n` per state in `nStates`, replays the states warm, and checks
// each against a cold build of the same sources. Returns the first mismatch, or "".
function replayMismatch(name: string, lib: string, m: string, nStates: string[], stem: string): string {
	const dir = `${root}/out/instanceWarm/${name}`;
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/lib.ms`, lib);
	writeFile(`${dir}/box.ms`, BOX);
	writeFile(`${dir}/m.ms`, m);
	writeFile(`${dir}/app.ms`, APP);
	writeFile(`${dir}/n.ms`, nStates[0]);
	let replay = "";
	for (let i = 1; i < nStates.length; i += 1) {
		writeFile(`${dir}/n${i}.ms`, nStates[i]);
		replay = replay + `n${i}.ms n.ms\n`;
	}
	writeFile(`${dir}/replay.txt`, replay);
	const warm = execFileResult(msc, ["build", "app.ms", "--hcr", "--watch-replay=replay.txt", "--emit=c"], dir);
	if (warm.exitCode != 0) return `warm replay failed: ${warm.output}${warm.errorOutput}`;
	const debug = `${dir}/out/debug`;
	for (let i = 0; i < nStates.length; i += 1) {
		writeFile(`${dir}/n.ms`, nStates[i]);
		for (const f of cFiles(debug)) removeAll(`${debug}/${f}`);
		const cold = execFileResult(msc, ["build", "app.ms", "--hcr", "--emit=c"], dir);
		if (cold.exitCode != 0) return `cold build of state ${i} failed: ${cold.output}${cold.errorOutput}`;
		const warmFiles = cFiles(`${debug}/watch${i}`);
		const coldFiles = cFiles(debug);
		if (warmFiles.join(",") != coldFiles.join(",")) return `state ${i}: warm emitted ${warmFiles.length} files, cold ${coldFiles.length}`;
		for (const f of coldFiles) {
			if (text(`${debug}/watch${i}/${f}`) != text(`${debug}/${f}`)) return `state ${i}: ${f} differs from a cold build`;
		}
		const defined = definitions(coldFiles, debug, stem);
		if (defined != 1) return `state ${i}: ${defined} definitions of ${stem} over Box`;
	}
	return "";
}

test "an importer edit that still mints a shared function instance leaves one definition and cold bytes" {
	const bad = replayMismatch("fnEdit", FN_LIB, FN_M, [FN_N_BOX(1), FN_N_BOX(2)], "findIt_");
	assert bad == "", bad;
}

test "an importer that stops minting a shared function instance leaves the other one defining it" {
	const bad = replayMismatch("fnDrop", FN_LIB, FN_M, [FN_N_BOX(1), FN_N_INT, FN_N_BOX(1)], "findIt_");
	assert bad == "", bad;
}

test "an importer edit that still mints a shared class instance leaves one definition and cold bytes" {
	const bad = replayMismatch("classEdit", CLASS_LIB, CLASS_M, [CLASS_N_BOX(1), CLASS_N_BOX(2)], "Wrap_get_");
	assert bad == "", bad;
}

test "an importer that stops minting a shared class instance leaves the other one defining it" {
	const bad = replayMismatch("classDrop", CLASS_LIB, CLASS_M, [CLASS_N_BOX(1), CLASS_N_INT, CLASS_N_BOX(1)], "Wrap_get_");
	assert bad == "", bad;
}
