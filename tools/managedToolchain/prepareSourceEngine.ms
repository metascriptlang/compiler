import { argv, exit, platform } from "std/process";
import { prepareSourceEngine } from "./sourceEngine";

const USAGE = "prepareSourceEngine --source-tarball T --source-sha256 H " +
	"--cache llvmEngine.cmake --cmake CMAKE --ninja NINJA --work DIR " +
	"--output NEW_DIR [--jobs N] [--cc CC] [--cxx CXX] [--linker LD]\n" +
	"--linker defaults to lld, and to the system linker on macOS";
const KEYS = [
	"--source-tarball", "--source-sha256", "--cache", "--cmake", "--ninja",
	"--work", "--output", "--jobs", "--cc", "--cxx", "--linker",
];
const REQUIRED = [
	"--source-tarball", "--source-sha256", "--cache", "--cmake", "--ninja",
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

function defaultLinker(): string {
	return platform == "darwin" || platform == "macos" ? "" : "lld";
}

function run(options: Map<string, string>): Result<void, string> {
	const value = (key: string): string => options.get(key) ?? "";
	const record = try prepareSourceEngine({
		tarball: value("--source-tarball"),
		sha256: value("--source-sha256"),
		cache: value("--cache"),
		cmake: value("--cmake"),
		ninja: value("--ninja"),
		work: value("--work"),
		output: value("--output"),
		jobs: try jobs(options.get("--jobs") ?? "16"),
		tools: {
			cc: options.get("--cc") ?? "clang",
			cxx: options.get("--cxx") ?? "clang++",
			linker: options.get("--linker") ?? defaultLinker(),
		},
	});
	console.log("built llvm " + record.llvmVersion + " from " +
		record.sourceTarball + " into " + value("--output"));
	return Result.ok(null);
}

function main(): int32 {
	const parsed = parseOptions(argv);
	if (!parsed.ok) {
		console.error(USAGE);
		console.error("prepareSourceEngine: error: " + parsed.error);
		return 2;
	}
	if (parsed.value.has("--help")) { console.log(USAGE); return 0; }
	const result = run(parsed.value);
	if (!result.ok) {
		console.error("prepareSourceEngine: error: " + result.error);
		return 1;
	}
	return 0;
}

when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
