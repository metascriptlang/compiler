import { execFileResult, env, platform, arch } from "std/process";
import { ensureDir, copyFile, exists } from "std/fs";

export function addressSanitizerArgs(workDir: string): string[] {
	const args = ["--sanitize=address"];
	if (env.get("MSC_NATIVE_TOOLCHAIN") != "" && platform != "windows") return args;
	args.push("--cc=clang");
	if (platform != "windows") return args;

	const cpu = match (arch) {
		"amd64" => "x86_64",
		"arm64" => "aarch64",
		"i386" => "i386",
		_ => "",
	};
	if (cpu == "") throw new Error(`Windows ASan target is unknown for ${arch}`);
	const got = execFileResult("clang", ["-print-resource-dir"]);
	if (!got.started || !got.pipeOk || got.exitCode != 0 || got.signal != 0 || got.output.trim() == "") {
		throw new Error("cannot locate host clang ASan resources");
	}
	const resource = got.output.trim().replaceAll("\\", "/");
	const shim = `${workDir.replaceAll("\\", "/")}/asan-resources`;
	if (!ensureDir(shim).ok) throw new Error(`cannot create ASan resources at ${shim}`);
	const copied = execFileResult("cmd", [
		"/c", "xcopy", "/E", "/I", "/Y", resource.replaceAll("/", "\\"), shim.replaceAll("/", "\\"),
	]);
	if (!copied.started || !copied.pipeOk || copied.exitCode != 0 || copied.signal != 0) {
		throw new Error(`cannot copy clang ASan resources: ${copied.output}${copied.errorOutput}`);
	}
	const gnu = `${shim}/lib/${cpu}-w64-windows-gnu`;
	if (!ensureDir(gnu).ok) throw new Error(`cannot create Windows-GNU ASan resources at ${gnu}`);
	const source = `${resource}/lib/windows`;
	const dynamic = `${source}/clang_rt.asan_dynamic-${cpu}.lib`;
	for (const name of ["libclang_rt.asan_dynamic.a", "libclang_rt.asan_dynamic.dll.a"]) {
		if (!copyFile(dynamic, `${gnu}/${name}`).ok) throw new Error(`cannot prepare ${gnu}/${name}`);
	}
	const thunk = `${source}/clang_rt.asan_dynamic_runtime_thunk-${cpu}.lib`;
	if (!copyFile(thunk, `${gnu}/libclang_rt.asan_dynamic_runtime_thunk.a`).ok) {
		throw new Error(`cannot prepare Windows ASan thunk for ${cpu}`);
	}
	if (!exists(`${shim}/include/mm_malloc.h`)) throw new Error(`clang ASan headers missing at ${shim}`);
	const flags = `--target=${cpu}-w64-mingw32 -resource-dir "${shim}"`;
	args.push(`--passC=${flags} -Wno-error=incompatible-pointer-types`);
	args.push(`--passL=${flags} -pthread`);
	return args;
}
