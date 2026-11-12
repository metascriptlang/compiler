import { argv, exit } from "std/process";
import { assembleBundle } from "./bundleAssembly";

const USAGE = "assembleBundle --engine ENGINE_DIR [--runtime-bundle BUNDLE_DIR] " +
	"[--overlay OVERLAY_DIR ...] --output NEW_DIR\n" +
	"ENGINE_DIR is a packageSourceEngine output; BUNDLE_DIR a bundle whose runtime/ " +
	"is copied beside it; each OVERLAY_DIR is a target runtime producer's output added over " +
	"both; at least one of the two names a runtime";

function main(): int32 {
	const options = new Map<string, string>();
	const overlays: string[] = [];
	for (let i: int32 = 1; i < argv.length; i += 1) {
		const key = argv[i];
		if (key == "--help" || key == "-h") { console.log(USAGE); return 0; }
		if (key != "--engine" && key != "--runtime-bundle" && key != "--output" && key != "--overlay") {
			console.error(USAGE);
			console.error("assembleBundle: error: unrecognized argument: " + key);
			return 2;
		}
		if (i + 1 >= argv.length) {
			console.error("assembleBundle: error: " + key + " requires a value");
			return 2;
		}
		i += 1;
		if (key == "--overlay") { overlays.push(argv[i]); }
		else { options.set(key, argv[i]); }
	}
	for (const key of ["--engine", "--output"]) {
		if ((options.get(key) ?? "") == "") {
			console.error(USAGE);
			console.error("assembleBundle: error: " + key + " is required");
			return 2;
		}
	}
	const packaged = assembleBundle(options.get("--engine") ?? "",
		options.get("--runtime-bundle") ?? "", options.get("--output") ?? "", overlays);
	if (!packaged.ok) {
		console.error("assembleBundle: error: " + packaged.error);
		return 1;
	}
	const contract = packaged.value.contract;
	console.log("assembled " + contract.host + " bundle " + contract.version +
		" identity " + contract.identity + " files=" + String(contract.files) +
		" targetRuntimeDirectories=" + packaged.value.targetRuntimeDirectories.join(",") +
		" into " + packaged.value.output);
	return 0;
}

when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
