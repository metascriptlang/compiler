import { arch, cwd, platform } from "std/process";
import { ensureDir, exists, isFile, join, removeAll, symlink, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import { readUtf8File } from "./textFile";
import { readStoredSiblingName } from "./nativeAlias";
import { samePhysicalFile } from "./nativePath";
import { writeEngineContract } from "./engineFiles";
import { engineHostKey } from "./sourceEnginePackage";
import { assembleBundle, caseTwins, linuxConfigTriples } from "./bundleAssembly";

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

function written(path: string, text: string): void {
	if (!ensureDir(path.slice(0, path.lastIndexOf("/"))).ok || !writeFile(path, text).ok) {
		throw new Error("cannot write " + path);
	}
}

function sealed(root: string, host: string, version: string): void {
	const done = writeEngineContract(root, host, version);
	if (!done.ok) { throw new Error(done.error); }
}

function pureCases(): void {
	const triples = linuxConfigTriples([
		"-target x86_64-unknown-linux5.10.0-gnu2.31.0\n-Xclang -target-cpu\n",
		"--target=aarch64-macos\n-target aarch64-apple-macos11.0\n",
		"-target x86_64-unknown-linux5.10.0-gnu2.31.0\n",
	]);
	expect(triples.join(",") == "x86_64-unknown-linux5.10.0-gnu2.31.0",
		"each Linux -target triple once, other targets ignored");
}

function engine(dir: string, host: string, version: string): string {
	const root = join(dir, "engine");
	written(join(root, "bin/llvm"), "engine");
	if (!symlink("llvm", join(root, "bin/clang")).ok) { throw new Error("symlink"); }
	written(join(root, "lib/clang/1/lib/x86_64-unknown-linux-gnu/libclang_rt.builtins.a"), "rt");
	written(join(root, "notices/provenance.json"), "{}\n");
	sealed(root, host, version);
	return root;
}

function runtimeBundle(dir: string, host: string, version: string, receipt: string): string {
	const root = join(dir, "old");
	written(join(root, "bin/clang"), "old engine");
	written(join(root, "lib/clang/1/lib/linux/libclang_rt.builtins-x86_64.a"), "old rt");
	written(join(root, "runtime/x86_64-linux-gnu.2.31.cfg"),
		"-target x86_64-unknown-linux5.10.0-gnu2.31.0\n-Xclang -target-cpu -Xclang x86-64\n" +
		"--sysroot=<CFGDIR>/x86_64-linux-gnu.2.31\n-Xclang -target-feature -Xclang -avx2\n");
	written(join(root, "runtime/x86_64-linux-gnu.2.31/libc.so.6"), "libc");
	if (!symlink("libc.so.6", join(root, "runtime/x86_64-linux-gnu.2.31/libc.so")).ok) {
		throw new Error("symlink");
	}
	written(join(root, "notices/bundle-provenance.json"), receipt);
	sealed(root, host, version);
	return root;
}

function assemblyCases(dir: string, host: string): void {
	const receipt = "{\"kind\": \"local-bundle-assembly\", \"runtimeProvenance\": \"runtime/notices/r.json\"}\n";
	const fresh = engine(dir, host, "1.2.3");
	const old = runtimeBundle(dir, host, "1.2.3", receipt);
	const output = join(dir, "bundle");
	const assembled = assembleBundle(fresh, old, output);
	if (!assembled.ok) { throw new Error("assembly refused: " + assembled.error); }
	expect(isFile(join(output, "lib/clang/1/lib/x86_64-unknown-linux-gnu/libclang_rt.builtins.a")) &&
		!exists(join(output, "lib/clang/1/lib/linux")), "the engine replaces the old engine whole");
	const libc = readStoredSiblingName(join(output, "runtime/x86_64-linux-gnu.2.31/libc.so"));
	expect(libc.ok && libc.value == "libc.so.6", "runtime aliases stay sibling links");
	const config = readUtf8File(join(output, "runtime/x86_64-linux-gnu.2.31.cfg"));
	expect(config.ok && config.value == "-target x86_64-unknown-linux5.10.0-gnu2.31.0\n" +
		"--sysroot=<CFGDIR>/x86_64-linux-gnu.2.31\n",
		"a copied config names no CPU, so the build's -march reaches the compiler");
	const text = readUtf8File(join(output, "notices/bundle-provenance.json"));
	expect(text.ok && text.value.contains("runtime/notices/r.json") &&
		text.value.contains("\"runtimeBundleIdentity\""),
		"the receipt keeps the runtime's receipts and names the runtime bundle");
	const linux = host.endsWith("-linux");
	expect(linux == isFile(join(output,
		"lib/clang/1/lib/x86_64-unknown-linux5.10.0-gnu2.31.0/libclang_rt.builtins.a")),
		"a Linux bundle copies the engine's runtime libraries under each config triple");
	expect(assembled.value.contract.host == host, "the contract is the host's");
	expectRefusal(assembleBundle(fresh, old, output), "exists", "an existing output");
	const stale = join(dir, "stale");
	const staleOld = runtimeBundle(stale, host, "1.2.4", receipt);
	expectRefusal(assembleBundle(fresh, staleOld, join(dir, "staleBundle")),
		"prepared for 1.2.4", "a runtime of another LLVM release");
	const layered = join(dir, "layered");
	const layeredOld = runtimeBundle(layered, host, "1.2.3",
		"{\"kind\": \"local-bundle-assembly\", \"overlays\": []}\n");
	expectRefusal(assembleBundle(fresh, layeredOld, join(dir, "layeredBundle")),
		"lists bundle overlays", "root overlays an engine swap would drop");
	expect(!exists(join(dir, "layeredBundle")), "a refused assembly publishes nothing");
	const overlay = join(dir, "overlay");
	written(join(overlay, "runtime/wasm32-wasi.cfg"), "-target wasm32-wasip1\n");
	written(join(overlay, "runtime/wasm32-wasip1/lib/wasm32-wasip1/libc.a"), "wasi libc");
	written(join(overlay, "lib/clang/1/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a"), "wasi rt");
	written(join(overlay, "runtime/aarch64-linux-musl.cfg"), "-target aarch64-unknown-linux-musl\n");
	written(join(overlay, "lib/clang/1/lib/aarch64-unknown-linux-musl/libclang_rt.builtins.a"), "musl rt");
	const carried = assembleBundle(fresh, old, join(dir, "carried"), [overlay]);
	if (!carried.ok) { throw new Error("overlay assembly refused: " + carried.error); }
	expect(isFile(join(dir, "carried/runtime/wasm32-wasi.cfg")) &&
		isFile(join(dir, "carried/runtime/wasm32-wasip1/lib/wasm32-wasip1/libc.a")) &&
		isFile(join(dir, "carried/lib/clang/1/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a")) &&
		isFile(join(dir, "carried/runtime/x86_64-linux-gnu.2.31.cfg")) &&
		carried.value.contract.files > assembled.value.contract.files,
		"an overlay adds its target beside the runtime bundle's, inside the contract");
	const muslBuiltins = readUtf8File(join(dir,
		"carried/lib/clang/1/lib/aarch64-unknown-linux-musl/libclang_rt.builtins.a"));
	expect(muslBuiltins.ok && muslBuiltins.value == "musl rt",
		"an overlay's Linux target keeps its own runtime libraries, not a copy of the engine's");
	const sharing = join(dir, "sharing");
	written(join(sharing, "runtime/wasm32-wasi.cfg"), "-target wasm32-wasip1\n");
	written(join(sharing, "runtime/other.cfg"), "-target other\n");
	const shared = assembleBundle(fresh, old, join(dir, "shared"), [overlay, sharing]);
	expect(shared.ok && isFile(join(dir, "shared/runtime/other.cfg")),
		"two overlays may carry the same file with the same bytes");
	const clashing = join(dir, "clashing");
	written(join(clashing, "runtime/x86_64-linux-gnu.2.31.cfg"), "-target other\n");
	expectRefusal(assembleBundle(fresh, old, join(dir, "clashed"), [clashing]),
		"would replace runtime/x86_64-linux-gnu.2.31.cfg", "an overlay over an existing file");
	expect(!exists(join(dir, "clashed")), "a refused overlay publishes nothing");
}

function storedOnceCases(dir: string, host: string): void {
	const fresh = join(dir, "engine");
	for (const tool of ["llvm.exe", "clang.exe", "ld.lld.exe"]) {
		written(join(fresh, "bin/" + tool), "multicall");
	}
	written(join(fresh, "bin/other.exe"), "another tool");
	written(join(fresh, "notices/provenance.json"), "{}\n");
	sealed(fresh, host, "1.2.3");
	const old = join(dir, "old");
	written(join(old, "runtime/windows/x86_64-windows-gnu.cfg"), "-target x86_64-w64-windows-gnu\n");
	written(join(old, "notices/bundle-provenance.json"), "{\"kind\": \"local-bundle-assembly\"}\n");
	sealed(old, host, "1.2.3");
	const output = join(dir, "bundle");
	const assembled = assembleBundle(fresh, old, output);
	if (!assembled.ok) { throw new Error("assembly refused: " + assembled.error); }
	const clang = samePhysicalFile(join(output, "bin/llvm.exe"), join(output, "bin/clang.exe"));
	const linker = samePhysicalFile(join(output, "bin/llvm.exe"), join(output, "bin/ld.lld.exe"));
	const other = samePhysicalFile(join(output, "bin/llvm.exe"), join(output, "bin/other.exe"));
	expect(clang.ok && clang.value && linker.ok && linker.value,
		"tool names with the same bytes are one file under several names");
	expect(other.ok && !other.value, "a tool with other bytes stays its own file");
	const text = readUtf8File(join(output, "bin/clang.exe"));
	expect(text.ok && text.value == "multicall" && assembled.value.contract.files == 9,
		"every name is in the contract with the tool's bytes");
	const overlay = join(dir, "overlay");
	written(join(overlay, "runtime/windows/x86_64-windows-gnu.cfg"), "-target x86_64-w64-windows-gnu\n");
	written(join(overlay, "runtime/wasm32-wasi.cfg"), "-target wasm32-wasip1\n");
	written(join(overlay, "lib/clang/1/lib/x86_64-w64-windows-gnu/libclang_rt.builtins.a"), "rt");
	const whole = assembleBundle(fresh, "", join(dir, "whole"), [overlay]);
	if (!whole.ok) { throw new Error("assembly from overlays refused: " + whole.error); }
	const receipt = readUtf8File(join(dir, "whole/notices/bundle-provenance.json"));
	expect(isFile(join(dir, "whole/runtime/windows/x86_64-windows-gnu.cfg")) &&
		isFile(join(dir, "whole/lib/clang/1/lib/x86_64-w64-windows-gnu/libclang_rt.builtins.a")) &&
		receipt.ok && receipt.value.contains("\"local-bundle-assembly\"") &&
		receipt.value.contains("\"wasm32-wasi.cfg\"") && receipt.value.contains("\"windows\"") &&
		!receipt.value.contains("runtimeBundleIdentity"),
		"an engine and overlays make a bundle whose receipt names each overlay's runtime entries");
	const twins = caseTwins(["runtime/t/include/xt_mark.h", "runtime/t/lib/libc.a", "runtime/t/include/xt_MARK.h"]);
	expect(twins.ok && twins.value == "runtime/t/include/xt_mark.h and runtime/t/include/xt_MARK.h",
		"two paths that differ only by case are named");
	const distinct = caseTwins(["runtime/t/a.h", "runtime/t/b.h", "runtime/T2/a.h"]);
	expect(distinct.ok && distinct.value == "", "paths that differ by more than case are not");
	const folding = join(dir, "folding");
	written(join(folding, "runtime/t/include/xt_mark.h"), "match");
	written(join(folding, "runtime/t/include/xt_MARK.h"), "target");
	const kept = readUtf8File(join(folding, "runtime/t/include/xt_mark.h"));
	if (kept.ok && kept.value == "match") {
		expectRefusal(assembleBundle(fresh, "", join(dir, "folded"), [folding]), "differ only by case",
			"an overlay whose payload a case-folding host cannot hold");
	}
	expectRefusal(assembleBundle(fresh, "", join(dir, "bare"), []), "needs a target runtime",
		"an engine with no runtime at all");
	expectRefusal(assembleBundle(fresh, join(dir, "whole"), join(dir, "swapped"), []),
		"lists bundle overlays", "an engine swap from a bundle whose overlays reach outside runtime/");
	expect(!exists(join(dir, "bare")) && !exists(join(dir, "swapped")), "a refused assembly publishes nothing");
}

function run(): void {
	pureCases();
	const host = engineHostKey(platform, arch);
	if (host.ok) {
		const token = randomUUIDSync();
		if (!token.ok) { throw new Error(token.error.message); }
		const dir = join(join(cwd(), "out"), "bundleAssemblyTest-" + token.value);
		storedOnceCases(join(dir, "storedOnce"), host.value);
		if (!host.value.endsWith("-windows")) { assemblyCases(dir, host.value); }
		if (!removeAll(dir).ok) { throw new Error("cannot remove " + dir); }
	}
	console.log("bundleAssembly: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
