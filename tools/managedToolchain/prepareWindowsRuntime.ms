import { argv, exit } from "std/process";
import { prepareWindowsRuntime } from "./windowsRuntime";
import { builtWindowsTarget } from "./windowsRuntimePlan";

const USAGE = "prepareWindowsRuntime --engine ENGINE_DIR --mingw-source DIR " +
	"--mingw-sha256 HEX --llvm-source DIR --llvm-sha256 HEX --cmake CMAKE " +
	"--ninja NINJA --fixtures DIR --output NEW_DIR [--jobs N] [--target T]";
const KEYS = [
	"--engine", "--mingw-source", "--mingw-sha256", "--llvm-source",
	"--llvm-sha256", "--cmake", "--ninja", "--fixtures", "--output", "--jobs",
	"--target",
];
const REQUIRED = [
	"--engine", "--mingw-source", "--mingw-sha256", "--llvm-source",
	"--llvm-sha256", "--cmake", "--ninja", "--fixtures", "--output",
];

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
		if (KEYS.indexOf(key) < 0) {
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
	for (const key of REQUIRED) {
		if ((options.get(key) ?? "") == "" && !options.has("--help")) {
			return Result.err(key + " is required");
		}
	}
	return Result.ok(options);
}

function jobs(text: string): Result<int32, string> {
	let value: int32 = 0;
	for (let i: int32 = 0; i < text.length; i += 1) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57 || value > 1000) {
			return Result.err("--jobs " + text + " is not a count");
		}
		value = value * 10 + (code - 48);
	}
	return value < 1 ? Result.err("--jobs must be at least 1") : Result.ok(value);
}

function run(options: Map<string, string>): Result<void, string> {
	try builtWindowsTarget(options.get("--target") ?? "x86_64-windows-gnu");
	const value = (key: string): string => options.get(key) ?? "";
	const receipt = try prepareWindowsRuntime({
		engine: value("--engine"), mingwSource: value("--mingw-source"),
		mingwSha256: value("--mingw-sha256"), llvmSource: value("--llvm-source"),
		llvmSha256: value("--llvm-sha256"), cmake: value("--cmake"),
		ninja: value("--ninja"), output: value("--output"),
		jobs: try jobs(options.get("--jobs") ?? "8"),
	}, value("--fixtures"));
	for (const variant of receipt.variants) {
		console.log(receipt.targets[0] + " " + variant.variant + ": " +
			String(variant.files.length) + " files");
	}
	console.log("builtins " + receipt.builtins + " sha256=" + receipt.builtinsSha256);
	console.log("mingw-w64 " + receipt.mingw.version + ", LLVM " + receipt.llvm.version);
	console.log("overlay written to " + value("--output"));
	return Result.ok(null);
}

function main(): int32 {
	const parsed = parseOptions(argv);
	if (!parsed.ok) {
		console.error(USAGE);
		console.error("prepareWindowsRuntime: error: " + parsed.error);
		return 2;
	}
	if (parsed.value.has("--help")) { console.log(USAGE); return 0; }
	const result = run(parsed.value);
	if (!result.ok) {
		console.error("prepareWindowsRuntime: error: " + result.error);
		return 1;
	}
	return 0;
}
when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
