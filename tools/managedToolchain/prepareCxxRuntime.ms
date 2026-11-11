import { argv, exit } from "std/process";
import { prepareCxxRuntime } from "./cxxRuntime";

const USAGE = "prepareCxxRuntime --bundle BUNDLE_DIR --target T --source-tarball T --source-sha256 H " +
	"--cmake CMAKE --ninja NINJA --work DIR --output NEW_DIR [--jobs N]\n" +
	"builds libc++, libc++abi and libunwind for target T from LLVM's runtimes/ with the bundle's clang " +
	"and writes the bundle with that C++ runtime, resealed, into NEW_DIR";
const KEYS = [
	"--bundle", "--target", "--source-tarball", "--source-sha256", "--cmake", "--ninja",
	"--work", "--output", "--jobs",
];
const REQUIRED = [
	"--bundle", "--target", "--source-tarball", "--source-sha256", "--cmake", "--ninja",
	"--work", "--output",
];

function parseOptions(args: string[]): Result<Map<string, string>, string> {
	const options = new Map<string, string>();
	for (let i: int32 = 1; i < args.length; i += 1) {
		const argument = args[i];
		if (argument == "--help" || argument == "-h") {
			options.set("--help", "yes");
			return Result.ok(options);
		}
		if (!KEYS.includes(argument)) {
			return Result.err("unrecognized argument: " + argument);
		}
		if (i + 1 >= args.length || args[i + 1].startsWith("--")) {
			return Result.err(argument + " requires a value");
		}
		i += 1;
		options.set(argument, args[i]);
	}
	if (options.has("--help")) { return Result.ok(options); }
	for (const key of REQUIRED) {
		if ((options.get(key) ?? "") == "") {
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
	const value = (key: string): string => options.get(key) ?? "";
	const result = try prepareCxxRuntime({
		bundle: value("--bundle"),
		tarball: value("--source-tarball"),
		sha256: value("--source-sha256"),
		cmake: value("--cmake"),
		ninja: value("--ninja"),
		work: value("--work"),
		output: value("--output"),
		jobs: try jobs(options.get("--jobs") ?? "8"),
		target: value("--target"),
	});
	console.log("C++ runtime for " + value("--target") + " from source; bundle " +
		result.contract.identity + " written to " + result.output +
		(result.removedZigNotice ? " (no Zig payload left: runtime/notices/zig removed)" : ""));
	return Result.ok(null);
}

function main(): int32 {
	const parsed = parseOptions(argv);
	if (!parsed.ok) {
		console.error(USAGE);
		console.error("prepareCxxRuntime: error: " + parsed.error);
		return 2;
	}
	if (parsed.value.has("--help")) { console.log(USAGE); return 0; }
	const result = run(parsed.value);
	if (!result.ok) {
		console.error("prepareCxxRuntime: error: " + result.error);
		return 1;
	}
	return 0;
}

when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
