import { argv, exit } from "std/process";
import {
	prepareWindowsEngine, verifyWindowsEngine, windowsSourcePathLiterals,
} from "./windowsEngine";
import { engineByteCount } from "./engineFiles";

const USAGE = "prepareWindowsEngine --llvm-root DIR --license FILE " +
	"--output NEW_DIR\nprepareWindowsEngine --verify BUNDLE_DIR " +
	"[--inspector LLVM_READOBJ]";

function parseOptions(args: string[]): Result<Map<string, string>, string> {
	const options = new Map<string, string>();
	for (let i: int32 = 1; i < args.length; i += 1) {
		const argument = args[i];
		if (argument == "--help" || argument == "-h") {
			options.set("--help", "yes");
			return Result.ok(options);
		}
		const equals = argument.indexOf("=");
		const key = equals < 0 ? argument : argument.slice(0, equals);
		if (key != "--llvm-root" && key != "--license" && key != "--output" &&
			key != "--verify" && key != "--inspector") {
			return Result.err("unrecognized argument: " + argument);
		}
		if (equals >= 0) {
			options.set(key, argument.slice(equals + 1, argument.length));
			continue;
		}
		if (i + 1 >= args.length || args[i + 1].startsWith("--")) {
			return Result.err(key + " requires a value");
		}
		i += 1;
		options.set(key, args[i]);
	}
	return Result.ok(options);
}
function run(options: Map<string, string>): Result<void, string> {
	const verify = options.get("--verify");
	if (verify != null && verify != "") {
		const audit = try verifyWindowsEngine(verify, options.get("--inspector"));
		console.log("verified host=" + audit.contract.host +
			" version=" + audit.contract.version + " pe=" + String(audit.peFiles));
		return Result.ok(null);
	}
	const llvm = options.get("--llvm-root");
	const output = options.get("--output");
	if (llvm == null || output == null || llvm == "" || output == "") {
		return Result.err("--llvm-root and --output are required");
	}
	const prepared = try prepareWindowsEngine(llvm,
		options.get("--license"), output);
	const audit = prepared.audit;
	console.log("prepared " + prepared.output);
	console.log("host=" + audit.contract.host +
		" version=" + audit.contract.version +
		" identity=" + audit.contract.identity);
	console.log("files=" + String(audit.contract.files) +
		" pe=" + String(audit.peFiles) +
		" bytes=" + String(try engineByteCount(prepared.output)));
	console.log("license=" + prepared.license.source +
		" sha256=" + prepared.license.sha256);
	const literals = try windowsSourcePathLiterals(prepared.output, llvm);
	for (const rel of literals) {
		const count = literals.get(rel);
		if (count != null) {
			console.log("source path literal in data: " + rel + " x" + String(count));
		}
	}
	console.log("redistribution NOT certified; local proof from an " +
		"installed LLVM and an operator-supplied license");
	return Result.ok(null);
}
function main(): int32 {
	const parsed = parseOptions(argv);
	if (!parsed.ok) {
		console.error(USAGE);
		console.error("prepareWindowsEngine: error: " + parsed.error);
		return 2;
	}
	if (parsed.value.has("--help")) { console.log(USAGE); return 0; }
	const verify = parsed.value.get("--verify");
	if ((verify == null || verify == "") &&
		((parsed.value.get("--llvm-root") ?? "") == "" ||
		(parsed.value.get("--output") ?? "") == "")) {
		console.error(USAGE);
		console.error("prepareWindowsEngine: error: " +
			"--llvm-root and --output are required");
		return 2;
	}
	const result = run(parsed.value);
	if (!result.ok) {
		console.error("prepareWindowsEngine: error: " + result.error);
		return 1;
	}
	return 0;
}
const code = main();
if (code != 0) { exit(code); }
