import { cwd } from "std/process";
import { ensureDir, join, removeAll, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import { parseJson, jsonValueOf, JsonKind, JsonValue } from "std/serialize/json";
import { getDynamicField } from "std/serialize/json/accessors";
import { stringifyPretty } from "std/serialize/json/stringify";
import {
	CXX_RECEIPT_KIND, CxxReceipt, CxxTargetRecord,
	configTriple, cxxCmakeArguments, cxxConfigText, cxxConfigureCommand, cxxLayout,
	prepareCxxRuntime, zigReceiptKinds,
} from "./cxxRuntime";

let cases: int32 = 0;

function expect(condition: boolean, what: string): void {
	cases += 1;
	if (!condition) { throw new Error("failed: " + what); }
}

function expectRefusal<T>(result: Result<T, string>, needle: string, what: string): void {
	cases += 1;
	if (result.ok) { throw new Error("accepted: " + what); }
	if (!result.error.contains(needle)) {
		throw new Error(what + ": " + result.error + " lacks " + needle);
	}
}

function text(value: JsonValue): string {
	if (value.kind == JsonKind.String) { return value.strVal; }
	return "";
}

function layoutCases(): void {
	const windows = cxxLayout("x86_64-windows-gnu");
	expect(windows.ok && windows.value.configDir == "runtime/windows" &&
		windows.value.directory == "x86_64-windows-gnu.cxx", "the Windows C++ runtime lives beside its C runtime");
	expect(windows.ok && windows.value.configs.join(" ") ==
		"x86_64-windows-gnu.cxx.cfg x86_64-windows-gnu.dll.cxx.cfg", "executables and DLLs each get a C++ config");
	const names = windows.ok ? windows.value.aliases.map((a) => a.alias + ">" + a.target).join(" ") : "";
	expect(names == "stdc++.lib>c++.lib supc++.lib>c++abi.lib gcc_eh.lib>unwind.lib gcc_s.lib>unwind.lib",
		"the GNU spellings a link line may name still resolve");
	expectRefusal(cxxLayout("x86_64-linux-gnu.2.31"), "only x86_64-windows-gnu",
		"glibc waits for its C runtime from source");
	const text = windows.ok ? cxxConfigText(windows.value) : "";
	expect(text == "-isystem <CFGDIR>/x86_64-windows-gnu.cxx/include/c++/v1\n" +
		"-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu.cxx\n$-lc++\n$-lc++abi\n$-lunwind\n",
		"the config names the installed headers, with their __config_site, and link-only archives");
}

function commandCases(): void {
	const args = cxxCmakeArguments("x86_64-windows-gnu", "x86_64-w64-windows-gnu").join(" ");
	expect(args.contains("-DLLVM_ENABLE_RUNTIMES=libunwind;libcxxabi;libcxx") &&
		args.contains("-DLIBCXXABI_USE_LLVM_UNWINDER=ON") &&
		args.contains("-DLIBCXX_ENABLE_SHARED=OFF") &&
		args.contains("-DCMAKE_CXX_COMPILER_TARGET=x86_64-w64-windows-gnu"),
		"static libc++ over libc++abi and libunwind for the config's triple");
	const layout = cxxLayout("x86_64-windows-gnu");
	if (!layout.ok) { throw new Error(layout.error); }
	const configure = cxxConfigureCommand("/u/cmake", "/u/ninja", "/s", "/b", "/i", "/bundle",
		layout.value, "x86_64-windows-gnu", "x86_64-w64-windows-gnu");
	const line = configure.args.join(" ");
	expect(configure.file == "/u/cmake" && line.contains("-S /s/runtimes -B /b") &&
		line.contains("-DCMAKE_INSTALL_PREFIX=/i"), "configure runs LLVM's runtimes/ into a private install");
	expect(line.contains("-DCMAKE_C_FLAGS=--no-default-config --config=/bundle/runtime/windows/x86_64-windows-gnu.cfg") &&
		line.contains("-DCMAKE_CXX_FLAGS=--no-default-config --config=/bundle/runtime/windows/x86_64-windows-gnu.cfg"),
		"the runtimes compile against the bundle's own C runtime, never a host libc");
	const triple = configTriple("-target x86_64-w64-windows-gnu\n-nostdinc\n");
	expect(triple.ok && triple.value == "x86_64-w64-windows-gnu", "the triple comes from the C config");
	expectRefusal(configTriple("-nostdinc\n"), "no -target", "a config without a target");
}

function receiptCases(): void {
	expect(zigReceiptKinds(["local-source-windows-runtime", CXX_RECEIPT_KIND]).length == 0,
		"with every runtime from source no receipt keeps the Zig notice");
	expect(zigReceiptKinds(["local-zig-cpp-runtime-proof", "local-bundle-assembly"]).join(" ") ==
		"local-zig-cpp-runtime-proof", "a Zig-produced payload keeps it");
	const archives = new Map<string, CxxTargetRecord>();
	archives.set("x86_64-windows-gnu", {
		directory: "windows/x86_64-windows-gnu.cxx",
		aliases: [{ alias: "stdc++.lib", target: "c++.lib" }],
		inputs: [{ name: "c++.lib", bytes: 3, sha256: "ab" }],
	});
	const receipt: CxxReceipt = {
		kind: CXX_RECEIPT_KIND, engineVersion: "23.1.4", target: "x86_64-windows-gnu", statement: "s",
		source: { llvmVersion: "23.1.4", sourceSha256: "ab", sourceTarball: "llvm-project-23.1.4.src.tar.xz" },
		cmakeArguments: [], archives, notices: [], redistributionCertified: false,
	};
	const parsed = parseJson(stringifyPretty(jsonValueOf(receipt), 2));
	if (!parsed.ok) { throw new Error(parsed.error); }
	const target = getDynamicField(getDynamicField(parsed.value, "archives"), "x86_64-windows-gnu");
	const alias = getDynamicField(target, "aliases");
	expect(text(getDynamicField(target, "directory")) == "windows/x86_64-windows-gnu.cxx" &&
		alias.kind == JsonKind.Array && alias.items.length == 1 &&
		text(getDynamicField(alias.items[0], "target")) == "c++.lib",
		"the receipt keeps the archives shape the Windows runtime replacement reads its aliases from");
}

function scratch(): string {
	const token = randomUUIDSync();
	if (!token.ok) { throw new Error(token.error.message); }
	const dir = join(join(cwd(), "out"), "cxxRuntimeTest-" + token.value);
	const made = ensureDir(dir);
	if (!made.ok) { throw new Error(made.error.message); }
	return dir;
}

function refusalCases(dir: string): void {
	const tarball = join(dir, "llvm-project-23.1.4.src.tar.xz");
	const tool = join(dir, "tool");
	for (const path of [tarball, tool]) {
		const written = writeFile(path, "x");
		if (!written.ok) { throw new Error(written.error.message); }
	}
	const request = {
		bundle: join(dir, "bundle"), tarball, sha256: "0".repeat(64), cmake: tool, ninja: tool,
		work: join(dir, "work"), output: join(dir, "out"), jobs: 1, target: "x86_64-windows-gnu",
	};
	expectRefusal(prepareCxxRuntime({ ...request, target: "x86_64-linux-gnu.2.31" }),
		"no source C++ runtime", "an unsupported target before any build");
	expectRefusal(prepareCxxRuntime({ ...request, jobs: 0 }), "--jobs", "zero jobs");
	expectRefusal(prepareCxxRuntime({ ...request, sha256: "AB" }), "--source-sha256", "a malformed digest");
	expectRefusal(prepareCxxRuntime(request), "bundle", "an unsealed bundle");
}

function run(): void {
	layoutCases();
	commandCases();
	receiptCases();
	const dir = scratch();
	refusalCases(dir);
	const cleaned = removeAll(dir);
	if (!cleaned.ok) { throw new Error(cleaned.error.message); }
	console.log("cxxRuntime: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
