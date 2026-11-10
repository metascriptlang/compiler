import { argv, exit } from "std/process";
import { packageSourceEngine } from "./sourceEnginePackage";

const USAGE = "packageSourceEngine --install INSTALL_DIR --source LLVM_SOURCE_DIR " +
	"--output NEW_DIR\n" +
	"INSTALL_DIR is a prepareSourceEngine output; LLVM_SOURCE_DIR the extracted " +
	"llvm-project-X.Y.Z.src it was built from";

function main(): int32 {
	const options = new Map<string, string>();
	for (let i: int32 = 1; i < argv.length; i += 1) {
		const key = argv[i];
		if (key == "--help" || key == "-h") { console.log(USAGE); return 0; }
		if (key != "--install" && key != "--source" && key != "--output") {
			console.error(USAGE);
			console.error("packageSourceEngine: error: unrecognized argument: " + key);
			return 2;
		}
		if (i + 1 >= argv.length) {
			console.error("packageSourceEngine: error: " + key + " requires a value");
			return 2;
		}
		i += 1;
		options.set(key, argv[i]);
	}
	for (const key of ["--install", "--source", "--output"]) {
		if ((options.get(key) ?? "") == "") {
			console.error(USAGE);
			console.error("packageSourceEngine: error: " + key + " is required");
			return 2;
		}
	}
	const packaged = packageSourceEngine(options.get("--install") ?? "",
		options.get("--source") ?? "", options.get("--output") ?? "");
	if (!packaged.ok) {
		console.error("packageSourceEngine: error: " + packaged.error);
		return 1;
	}
	const contract = packaged.value.contract;
	console.log("packaged " + contract.host + " engine " + contract.version +
		" identity " + contract.identity + " files=" + String(contract.files) +
		" into " + packaged.value.output);
	return 0;
}

when (!testBuild) {
	const code = main();
	if (code != 0) { exit(code); }
}
