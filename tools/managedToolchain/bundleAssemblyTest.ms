import { arch, cwd, platform } from "std/process";
import { ensureDir, exists, isFile, join, removeAll, symlink, writeFile } from "std/fs";
import { randomUUIDSync } from "std/crypto";
import { readUtf8File } from "./textFile";
import { readStoredSiblingName } from "./nativeAlias";
import { writeEngineContract } from "./engineFiles";
import { engineHostKey } from "./sourceEnginePackage";
import { assembleBundle, linuxConfigTriples } from "./bundleAssembly";

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
		"-target x86_64-unknown-linux5.10.0-gnu2.31.0\n--sysroot=<CFGDIR>/x86_64-linux-gnu.2.31\n");
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
}

function run(): void {
	pureCases();
	const host = engineHostKey(platform, arch);
	if (host.ok) {
		const token = randomUUIDSync();
		if (!token.ok) { throw new Error(token.error.message); }
		const dir = join(join(cwd(), "out"), "bundleAssemblyTest-" + token.value);
		assemblyCases(dir, host.value);
		if (!removeAll(dir).ok) { throw new Error("cannot remove " + dir); }
	}
	console.log("bundleAssembly: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
