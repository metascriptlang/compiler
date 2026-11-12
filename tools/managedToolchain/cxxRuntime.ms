import { ensureDir, isFile, join } from "std/fs";
import { sha256File } from "./fileDigest";
import { copyBundleTree } from "./bundleAssembly";
import { copyEngineFile, engineFileSize, engineIo, writeEngineText } from "./engineFiles";

const COMPONENTS: string[] = ["libcxx", "libcxxabi", "libunwind"];

export struct CxxAlias {
	alias: string;
	target: string;
}

export struct CxxArchive {
	name: string;
	built: string;
}

export struct CxxLayout {
	directory: string;
	configs: string[];
	archives: CxxArchive[];
	aliases: CxxAlias[];
}

export struct CxxFile {
	bytes: int64;
	name: string;
	sha256: string;
}

export struct CxxRecord {
	aliases: CxxAlias[];
	cmakeArguments: string[];
	directory: string;
	files: CxxFile[];
	notices: string[];
}

export function cxxLayout(target: string): CxxLayout {
	return {
		directory: target + ".cxx",
		configs: [target + ".cxx.cfg", target + ".dll.cxx.cfg"],
		archives: [
			{ name: "c++.lib", built: "lib/libc++.a" },
			{ name: "c++abi.lib", built: "lib/libc++abi.a" },
			{ name: "unwind.lib", built: "lib/libunwind.a" },
		],
		aliases: [
			{ alias: "stdc++.lib", target: "c++.lib" },
			{ alias: "supc++.lib", target: "c++abi.lib" },
			{ alias: "gcc_eh.lib", target: "unwind.lib" },
			{ alias: "gcc_s.lib", target: "unwind.lib" },
		],
	};
}

export function cxxConfigText(layout: CxxLayout): string {
	return "-isystem <CFGDIR>/" + layout.directory + "/include/c++/v1\n" +
		"-idirafter <CFGDIR>/" + layout.directory + "/include\n" +
		"-Xlinker -L -Xlinker <CFGDIR>/" + layout.directory + "\n" +
		"$-lc++\n$-lc++abi\n$-lunwind\n";
}

// The flags llvm-mingw's build-libcxx.sh gives LLVM's runtimes/ for a static mingw libc++.
export function cxxCmakeArguments(triple: string): string[] {
	return [
		"-DCMAKE_BUILD_TYPE=Release",
		"-DCMAKE_SYSTEM_NAME=Windows",
		"-DCMAKE_C_COMPILER_TARGET=" + triple,
		"-DCMAKE_CXX_COMPILER_TARGET=" + triple,
		"-DCMAKE_C_COMPILER_WORKS=TRUE",
		"-DCMAKE_CXX_COMPILER_WORKS=TRUE",
		"-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx",
		"-DLIBUNWIND_USE_COMPILER_RT=TRUE",
		"-DLIBUNWIND_ENABLE_SHARED=OFF",
		"-DLIBUNWIND_ENABLE_STATIC=ON",
		"-DLIBCXX_USE_COMPILER_RT=ON",
		"-DLIBCXX_ENABLE_SHARED=OFF",
		"-DLIBCXX_ENABLE_STATIC=ON",
		"-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE",
		"-DLIBCXX_CXX_ABI=libcxxabi",
		"-DLIBCXX_LIBDIR_SUFFIX=",
		"-DLIBCXX_INCLUDE_TESTS=FALSE",
		"-DLIBCXX_INCLUDE_BENCHMARKS=FALSE",
		"-DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=FALSE",
		"-DLIBCXXABI_USE_COMPILER_RT=ON",
		"-DLIBCXXABI_USE_LLVM_UNWINDER=ON",
		"-DLIBCXXABI_ENABLE_SHARED=OFF",
		"-DLIBCXXABI_LIBDIR_SUFFIX=",
	];
}

// stage is a toolchain whose bin/ holds the engine and whose C runtime config is complete: the runtimes compile
// against that C runtime, never a host libc.
export function cxxConfigureArguments(
	ninja: string, source: string, build: string, install: string, stage: string,
	config: string, triple: string, prefixMaps: string[],
): string[] {
	const flags = ["--no-default-config", "--config=" + config, ...prefixMaps].join(" ");
	const tool = (name: string): string => join(stage, "bin/" + name);
	return [
		"-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + ninja,
		"-S", join(source, "runtimes"), "-B", build,
		"-DCMAKE_INSTALL_PREFIX=" + install,
		"-DCMAKE_C_COMPILER=" + tool("clang"),
		"-DCMAKE_CXX_COMPILER=" + tool("clang++"),
		"-DCMAKE_AR=" + tool("llvm-ar"),
		"-DCMAKE_RANLIB=" + tool("llvm-ranlib"),
		"-DCMAKE_C_FLAGS=" + flags,
		"-DCMAKE_CXX_FLAGS=" + flags,
		"-DCMAKE_ASM_FLAGS=" + flags,
		...cxxCmakeArguments(triple),
	];
}

// Lay the runtimes install out beside the C runtime in configDir: headers, archives under the names a link line
// may spell, the C++ configs and each component's notice.
export function installCxxRuntime(
	install: string, source: string, configDir: string, layout: CxxLayout, cmakeArguments: string[],
): Result<CxxRecord, string> {
	const directory = join(configDir, layout.directory);
	try engineIo(ensureDir(join(directory, "include")));
	try copyBundleTree(join(install, "include"), join(directory, "include"), "", []);
	const files: CxxFile[] = [];
	for (const archive of layout.archives) {
		const built = join(install, archive.built);
		if (!isFile(built)) { return Result.err("the runtimes build installed no " + archive.built); }
		const to = join(directory, archive.name);
		try copyEngineFile(built, to);
		files.push({ bytes: try engineFileSize(to), name: archive.name, sha256: try sha256File(to) });
	}
	for (const alias of layout.aliases) {
		try copyEngineFile(join(directory, alias.target), join(directory, alias.alias));
	}
	for (const config of layout.configs) {
		try writeEngineText(join(configDir, config), cxxConfigText(layout));
	}
	const notices: string[] = [];
	for (const component of COMPONENTS) {
		const notice = "notices/" + component + "/LICENSE.TXT";
		try copyEngineFile(join(join(source, component), "LICENSE.TXT"), join(configDir, notice));
		notices.push(notice);
	}
	return Result.ok({
		aliases: layout.aliases, cmakeArguments, directory: layout.directory, files, notices,
	});
}
