import { argv, exit, execFile, findOnPath, platform } from "std/process";
import { basename, dirname, isLinkLike, join, removeAll } from "std/fs";
import { IoErrorKind } from "std/io/errors";
import { captureToolUtf8 } from "./processCapture";
import { readUtf8File } from "./textFile";
import { renameNoReplace } from "./nativePublication";
import {
	FileLinks, absoluteEnginePath, inventoryTree, verifyEngineContract,
	writeEngineContract, writeEngineText,
} from "./engineFiles";
import { dynamicListText, nmFunctions } from "./sanitizerSyms";

const USAGE = "addSanitizerSyms --bundle LINUX_BUNDLE --extra " +
	"compiler-rt/lib/ubsan_minimal/ubsan.syms.extra --output NEW_DIR";
const ARCHIVE_PREFIX = "libclang_rt.ubsan_minimal";

function parseOptions(args: string[]): Result<Map<string, string>, string> {
	const options = new Map<string, string>();
	for (let i: int32 = 1; i < args.length; i += 1) {
		const key = args[i];
		if (key == "--help" || key == "-h") {
			options.set("--help", "yes");
			return Result.ok(options);
		}
		if (key != "--bundle" && key != "--extra" && key != "--output") {
			return Result.err("unrecognized argument: " + key);
		}
		if (i + 1 >= args.length || args[i + 1].startsWith("--")) {
			return Result.err(key + " requires a value");
		}
		i += 1;
		options.set(key, args[i]);
	}
	if (options.has("--help")) { return Result.ok(options); }
	for (const key of ["--bundle", "--extra", "--output"]) {
		if ((options.get(key) ?? "") == "") {
			return Result.err(key + " is required");
		}
	}
	return Result.ok(options);
}

function minimalArchives(root: string): Result<string[], string> {
	const archives: string[] = [];
	for (const rel of try inventoryTree(join(root, "lib/clang"),
		FileLinks.ContainedFiles)) {
		const name = basename(rel);
		if (name.startsWith(ARCHIVE_PREFIX) && name.endsWith(".a")) {
			archives.push("lib/clang/" + rel);
		}
	}
	if (archives.length == 0) {
		return Result.err(root + " ships no " + ARCHIVE_PREFIX + " archive");
	}
	return Result.ok(archives);
}

function writeLists(
	root: string,
	archives: string[],
	extras: string[],
): Result<void, string> {
	const nm = join(root, "bin/llvm-nm");
	for (const rel of archives) {
		const listed = captureToolUtf8(nm, [join(root, rel)]);
		if (!listed.ok) { return Result.err(nm + ": " + listed.error); }
		if (listed.value.returnCode != 0) {
			return Result.err(nm + " " + rel + " failed: " +
				listed.value.errorOutput);
		}
		const text = try dynamicListText(nmFunctions(listed.value.output),
			extras);
		try writeEngineText(join(root, rel + ".syms"), text);
		console.log("wrote " + rel + ".syms");
	}
	return Result.ok(null);
}

function run(options: Map<string, string>): Result<string, string> {
	if (platform != "linux") {
		return Result.err("the dynamic list is an ELF link input; run on Linux");
	}
	const bundle = try absoluteEnginePath(options.get("--bundle") ?? "");
	const output = try absoluteEnginePath(options.get("--output") ?? "");
	if (isLinkLike(output).ok) {
		return Result.err("output " + output + " exists; it is never replaced");
	}
	const contract = try verifyEngineContract(bundle);
	const extras = (try readUtf8File(try absoluteEnginePath(
		options.get("--extra") ?? ""))).split("\n");
	const cp = findOnPath("cp");
	if (cp == "") { return Result.err("cp is not on PATH"); }
	const partial = join(dirname(output), "." + basename(output) + ".partial");
	if (isLinkLike(partial).ok) {
		return Result.err(partial + " exists from an earlier run; remove it");
	}
	if (execFile(cp, ["-a", bundle, partial]) != 0) {
		removeAll(partial);
		return Result.err("cp -a " + bundle + " " + partial + " failed");
	}
	const sealed = sealWithLists(partial, contract.host, contract.version,
		extras);
	if (!sealed.ok) {
		removeAll(partial);
		return Result.err(sealed.error);
	}
	const published = renameNoReplace(partial, output);
	if (!published.ok) {
		removeAll(partial);
		return Result.err(published.error.kind == IoErrorKind.AlreadyExists ?
			"output " + output + " exists; it is never replaced" :
			published.error.message);
	}
	return Result.ok(sealed.value);
}

function sealWithLists(
	root: string,
	host: string,
	version: string,
	extras: string[],
): Result<string, string> {
	try writeLists(root, try minimalArchives(root), extras);
	try writeEngineContract(root, host, version);
	return Result.ok((try verifyEngineContract(root)).identity);
}

function main(): int32 {
	const parsed = parseOptions(argv);
	if (!parsed.ok) {
		console.error(USAGE);
		console.error("addSanitizerSyms: error: " + parsed.error);
		return 2;
	}
	if (parsed.value.has("--help")) { console.log(USAGE); return 0; }
	const identity = run(parsed.value);
	if (!identity.ok) {
		console.error("addSanitizerSyms: error: " + identity.error);
		return 1;
	}
	console.log("bundle written to " + (parsed.value.get("--output") ?? "") +
		" identity=" + identity.value);
	return 0;
}

when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
