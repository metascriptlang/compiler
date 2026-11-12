import { argv, exit } from "std/process";
import { decimal } from "./windowsRuntimePlan";
import { prepareTargetRuntime } from "./targetRuntime";

const USAGE = "prepareTargetRuntime --engine ENGINE_OR_BUNDLE_DIR --target T --llvm-tarball T " +
	"--llvm-sha256 H --sources DIR --cmake CMAKE --ninja NINJA --work DIR --output NEW_DIR [--jobs N]\n" +
	"builds the C runtime and builtins of target T from pinned upstream source with the engine's " +
	"clang and writes them into NEW_DIR as an overlay of bundle paths; DIR of --sources holds the " +
	"pinned source archives under their upstream file names";
const KEYS = [
	"--engine", "--target", "--llvm-tarball", "--llvm-sha256", "--sources", "--cmake", "--ninja",
	"--work", "--output", "--jobs",
];

function main(): int32 {
	const options = new Map<string, string>();
	for (let i: int32 = 1; i < argv.length; i += 1) {
		const key = argv[i];
		if (key == "--help" || key == "-h") { console.log(USAGE); return 0; }
		if (!KEYS.includes(key) || i + 1 >= argv.length) {
			console.error(USAGE);
			console.error("prepareTargetRuntime: error: unrecognized or incomplete argument: " + key);
			return 2;
		}
		i += 1;
		options.set(key, argv[i]);
	}
	for (const key of KEYS) {
		if (key != "--jobs" && (options.get(key) ?? "") == "") {
			console.error(USAGE);
			console.error("prepareTargetRuntime: error: " + key + " is required");
			return 2;
		}
	}
	const jobs = decimal(options.get("--jobs") ?? "8");
	if (jobs == null) {
		console.error("prepareTargetRuntime: error: --jobs must be a number");
		return 2;
	}
	const written = prepareTargetRuntime({
		engine: options.get("--engine") ?? "",
		target: options.get("--target") ?? "",
		llvmTarball: options.get("--llvm-tarball") ?? "",
		llvmSha256: options.get("--llvm-sha256") ?? "",
		sources: options.get("--sources") ?? "",
		cmake: options.get("--cmake") ?? "",
		ninja: options.get("--ninja") ?? "",
		work: options.get("--work") ?? "",
		output: options.get("--output") ?? "",
		jobs,
	});
	if (!written.ok) {
		console.error("prepareTargetRuntime: error: " + written.error);
		return 1;
	}
	console.log("runtime of " + (options.get("--target") ?? "") + " written to " + written.value);
	return 0;
}

when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
