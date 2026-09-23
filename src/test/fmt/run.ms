// Lossless-fmt lane: formats every .ms under the roots in memory, never writes.
// A file is red when fmt changes a token (checkLossless) or a second pass is not
// byte-identical. Roots come from MSFMT_ROOTS (comma-separated), else the repo's src/ and std/ plus neon's.

import { readFile, readDir, exists, isDir } from "std/fs";
import { env, exit } from "std/process";
import { registerCoreParsers } from "../../parser/statements/core";
import { parseSource } from "../../parser/statements/validation";
import { resetAllSideChannels } from "../../parser/context";
import { formatNode } from "../../compiler/fmt/printer/index";
import { defaultFormatOptions } from "../../compiler/fmt/options";
import { checkLossless } from "../../compiler/fmt/lossless";

function collect(dir: string, out: string[]): void {
	for (const entry of readDir(dir)) {
		if (entry.endsWith("/")) {
			collect(dir + "/" + entry.byteSlice(0, entry.byteLength - 1), out);
		} else if (entry.endsWith(".ms")) {
			out.push(dir + "/" + entry);
		}
	}
}

function format(source: string): Result<string, string> {
	resetAllSideChannels();
	const parsed = parseSource(source);
	if (!parsed.ok) return Result.err("parse error: " + parsed.error);
	const options = defaultFormatOptions();
	options.source = source;
	return formatNode(parsed.value, options);
}

function roots(): string[] {
	const given = env.get("MSFMT_ROOTS");
	if (given != "") return given.split(",");
	let home = env.get("HOME");
	if (home == "") home = env.get("USERPROFILE");
	return ["src", "std", home + "/metascript/neon/src", home + "/metascript/neon/tests"];
}

registerCoreParsers();
const explicitRoots = env.get("MSFMT_ROOTS") != "";
const files: string[] = [];
for (const root of roots()) {
	if (!exists(root) || !isDir(root)) {
		if (explicitRoots || root == "src" || root == "std") {
			console.log("missing root " + root);
			exit(2);
		}
		console.log("skipped " + root + ": not checked out");
		continue;
	}
	collect(root, files);
}

let lossy = 0;
let unstable = 0;
let broken = 0;
for (const file of files) {
	const read = readFile(file);
	if (!read.ok) {
		console.log("UNREADABLE " + file);
		broken += 1;
		continue;
	}
	const source = read.value;
	const once = format(source);
	if (!once.ok) {
		console.log("NO-FMT " + file + ": " + once.error);
		broken += 1;
		continue;
	}
	const check = checkLossless(source, once.value);
	if (!check.ok) {
		console.log("LOSSY " + file + ": " + check.error);
		lossy += 1;
	}
	const twice = format(once.value);
	if (!twice.ok || twice.value != once.value) {
		console.log("UNSTABLE " + file);
		unstable += 1;
	}
}

console.log(files.length.toString() + " files · " + lossy.toString() + " lossy · " + unstable.toString() + " unstable · " + broken.toString() + " no-fmt");
exit(lossy + unstable + broken > 0 ? 1 : 0);
