import { execFileResult, cwd, env, platform, arch } from "std/process";
import { ensureDir, exists } from "std/fs";
import { addressSanitizerArgs } from "../nativeSanitizer";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardBareHeapSanitizer`;
ensureDir(dir);
const bin = `${dir}/useAfterFree${platform == "windows" ? ".exe" : ""}`;
const args = [
	"build", `${root}/src/test/guard/fixtures/bareHeapUseAfterFree.ms`,
	"--os=bare", `--output=${bin}`,
];
for (const arg of addressSanitizerArgs(dir)) args.push(arg);
const built = execFileResult(msc, args, root);
if (!built.started || !built.pipeOk || built.exitCode != 0 || built.signal != 0 || !exists(bin)) {
	throw new Error(`ASan control build failed: ${built.output}${built.errorOutput}`);
}
let runtimeDir = "";
if (platform == "windows") {
	const resource = execFileResult("clang", ["-print-resource-dir"]);
	if (!resource.started || !resource.pipeOk || resource.exitCode != 0 || resource.output.trim() == "") {
		throw new Error("cannot locate clang ASan runtime");
	}
	runtimeDir = `${resource.output.trim().replaceAll("\\", "/")}/lib/windows`;
	const runtimeArch = match (arch) {
		"amd64" => "x86_64",
		"arm64" => "aarch64",
		"i386" => "i386",
		_ => "",
	};
	if (runtimeArch == "" || !exists(`${runtimeDir}/clang_rt.asan_dynamic-${runtimeArch}.dll`)) {
		throw new Error(`missing clang ASan runtime for ${arch}`);
	}
}
const oldPath = env.get("PATH");
if (runtimeDir != "") env.set("PATH", `${runtimeDir};${oldPath}`);
const ran = execFileResult(bin, [], dir);
if (runtimeDir != "") env.set("PATH", oldPath);
const output = ran.output + ran.errorOutput;
if (!ran.started || !ran.pipeOk || (ran.exitCode == 0 && ran.signal == 0) || !output.includes("ERROR: AddressSanitizer: heap-use-after-free")) {
	throw new Error(`ASan did not observe the bare free: ${output}`);
}
console.log("GUARD-OK");
