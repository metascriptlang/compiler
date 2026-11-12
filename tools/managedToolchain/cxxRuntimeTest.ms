import { cwd } from "std/process";
import { ensureDir, dirname, isFile, join, removeAll, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import { readUtf8File } from "./textFile";
import {
	cxxCmakeArguments, cxxConfigText, cxxConfigureArguments, cxxLayout, installCxxRuntime,
} from "./cxxRuntime";

let cases: int32 = 0;

function expect(condition: boolean, what: string): void {
	cases += 1;
	if (!condition) { throw new Error("failed: " + what); }
}

function layoutCases(): void {
	const windows = cxxLayout("x86_64-windows-gnu");
	expect(windows.directory == "x86_64-windows-gnu.cxx", "the Windows C++ runtime lives beside its C runtime");
	expect(windows.configs.join(" ") == "x86_64-windows-gnu.cxx.cfg x86_64-windows-gnu.dll.cxx.cfg",
		"executables and DLLs each get a C++ config");
	const names = windows.aliases.map((a) => a.alias + ">" + a.target).join(" ");
	expect(names == "stdc++.lib>c++.lib supc++.lib>c++abi.lib gcc_eh.lib>unwind.lib gcc_s.lib>unwind.lib",
		"the GNU spellings a link line may name still resolve");
	expect(cxxConfigText(windows) == "-isystem <CFGDIR>/x86_64-windows-gnu.cxx/include/c++/v1\n" +
		"-idirafter <CFGDIR>/x86_64-windows-gnu.cxx/include\n" +
		"-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu.cxx\n$-lc++\n$-lc++abi\n$-lunwind\n",
		"the config names the installed headers, libunwind's behind every system one, and link-only archives");
}

function commandCases(): void {
	const args = cxxCmakeArguments("x86_64-w64-windows-gnu").join(" ");
	expect(args.contains("-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx") &&
		args.contains("-DLIBCXXABI_USE_LLVM_UNWINDER=ON") &&
		args.contains("-DLIBCXX_ENABLE_SHARED=OFF") &&
		args.contains("-DCMAKE_CXX_COMPILER_TARGET=x86_64-w64-windows-gnu"),
		"static libc++ over libc++abi and libunwind for the config's triple");
	const line = cxxConfigureArguments("/u/ninja", "/s", "/b", "/i", "/stage",
		"/stage/runtime/windows/x.cfg", "x86_64-w64-windows-gnu", ["-ffile-prefix-map=/s=/llvm-project"]).join(" ");
	expect(line.contains("-S /s/runtimes -B /b") && line.contains("-DCMAKE_INSTALL_PREFIX=/i"),
		"configure runs LLVM's runtimes/ into a private install");
	expect(line.contains("-DCMAKE_CXX_COMPILER=/stage/bin/clang++") &&
		line.contains("-DCMAKE_CXX_FLAGS=--no-default-config --config=/stage/runtime/windows/x.cfg " +
			"-ffile-prefix-map=/s=/llvm-project"),
		"the runtimes compile with the stage's clang against its C runtime, naming no producer path");
}

function write(path: string, text: string): void {
	const made = ensureDir(dirname(path));
	if (!made.ok) { throw new Error(made.error.message); }
	const written = writeFile(path, text);
	if (!written.ok) { throw new Error(written.error.message); }
}

function installCases(dir: string): void {
	const install = join(dir, "install");
	const source = join(dir, "llvm");
	const windows = join(dir, "runtime/windows");
	const layout = cxxLayout("x86_64-windows-gnu");
	write(join(install, "include/c++/v1/vector"), "v");
	write(join(install, "include/libunwind.h"), "u");
	write(join(install, "lib/libc++.a"), "c++");
	write(join(install, "lib/libc++abi.a"), "abi");
	for (const component of ["libcxx", "libcxxabi", "libunwind"]) {
		write(join(source, component + "/LICENSE.TXT"), component);
	}
	const partial = installCxxRuntime(install, source, join(dir, "partial"), layout, []);
	expect(!partial.ok && partial.error.contains("lib/libunwind.a"), "a build without an archive is refused by name");
	write(join(install, "lib/libunwind.a"), "unwind");
	const record = installCxxRuntime(install, source, windows, layout, ["-DX=1"]);
	if (!record.ok) { throw new Error(record.error); }
	const directory = join(windows, "x86_64-windows-gnu.cxx");
	expect(isFile(join(directory, "include/c++/v1/vector")) && isFile(join(directory, "include/libunwind.h")),
		"libc++'s and libunwind's headers are installed");
	const alias = readUtf8File(join(directory, "gcc_s.lib"));
	expect(alias.ok && alias.value == "unwind", "an alias holds its target's bytes");
	const config = readUtf8File(join(windows, "x86_64-windows-gnu.dll.cxx.cfg"));
	expect(config.ok && config.value == cxxConfigText(layout), "each variant gets the C++ config");
	expect(record.value.files.map((f) => f.name + ":" + String(f.bytes)).join(" ") ==
		"c++.lib:3 c++abi.lib:3 unwind.lib:6" && record.value.directory == "x86_64-windows-gnu.cxx" &&
		record.value.cmakeArguments.join(" ") == "-DX=1", "the record names what was built and how");
	expect(record.value.notices.join(" ") ==
		"notices/libcxx/LICENSE.TXT notices/libcxxabi/LICENSE.TXT notices/libunwind/LICENSE.TXT" &&
		isFile(join(windows, "notices/libunwind/LICENSE.TXT")), "each component's notice ships beside the runtime");
}

function run(): void {
	layoutCases();
	commandCases();
	const token = randomUUIDSync();
	if (!token.ok) { throw new Error(token.error.message); }
	const dir = join(join(cwd(), "out"), "cxxRuntimeTest-" + token.value);
	installCases(dir);
	const cleaned = removeAll(dir);
	if (!cleaned.ok) { throw new Error(cleaned.error.message); }
	console.log("cxxRuntime: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
