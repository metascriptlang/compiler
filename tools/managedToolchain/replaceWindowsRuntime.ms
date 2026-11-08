import { argv, exit } from "std/process";
import { ensureDir } from "std/fs";
import { replaceWindowsRuntime, runWindowsBundle } from "./windowsRuntimeBundle";

const USAGE = "replaceWindowsRuntime --bundle BUNDLE_DIR --overlay OVERLAY_DIR --output NEW_DIR " +
	"[--fixtures DIR]\n  --fixtures links and runs the new bundle's C, C++ and UBSan programs (Windows hosts)";

function parseOptions(args: string[]): Result<Map<string, string>, string> {
	const options = new Map<string, string>();
	for (let i: int32 = 1; i < args.length; i += 1) {
		const key = args[i];
		if (key == "--help" || key == "-h") { options.set("--help", "yes"); return Result.ok(options); }
		if (key != "--bundle" && key != "--overlay" && key != "--output" && key != "--fixtures") {
			return Result.err("unrecognized argument: " + key);
		}
		if (i + 1 >= args.length || args[i + 1].startsWith("--")) { return Result.err(key + " requires a value"); }
		i += 1;
		options.set(key, args[i]);
	}
	for (const key of ["--bundle", "--overlay", "--output"]) {
		if ((options.get(key) ?? "") == "") { return Result.err(key + " is required"); }
	}
	return Result.ok(options);
}

function run(options: Map<string, string>): Result<void, string> {
	const replaced = try replaceWindowsRuntime(options.get("--bundle") ?? "", options.get("--overlay") ?? "",
		options.get("--output") ?? "");
	console.log("bundle written to " + replaced.output);
	console.log("identity=" + replaced.identity + " kept=" + String(replaced.kept) + " removed=" +
		String(replaced.removed) + " added=" + String(replaced.added));
	for (const file of replaced.superseded) {
		console.log("superseded " + file.path + " " + file.previousSha256 + " -> " + file.sha256);
	}
	const fixtures = options.get("--fixtures") ?? "";
	if (fixtures != "") {
		const work = replaced.output + ".proof";
		const made = ensureDir(work);
		if (!made.ok) { return Result.err(made.error.message); }
		for (const line of try runWindowsBundle(replaced.output, fixtures, work)) { console.log(line); }
	}
	console.log("redistribution NOT certified; local proof");
	return Result.ok(null);
}

function main(): int32 {
	const parsed = parseOptions(argv);
	if (!parsed.ok) {
		console.error(USAGE);
		console.error("replaceWindowsRuntime: error: " + parsed.error);
		return 2;
	}
	if (parsed.value.has("--help")) { console.log(USAGE); return 0; }
	const result = run(parsed.value);
	if (!result.ok) {
		console.error("replaceWindowsRuntime: error: " + result.error);
		return 1;
	}
	return 0;
}
when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
