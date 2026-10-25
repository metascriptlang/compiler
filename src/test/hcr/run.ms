// HCR runner: msc run --target=raiser src/test/hcr/run.ms, from the recompiler root.
// Env: MSC=<path to msc> (default: ./msc, else installed msc).
import { execFileResult, ExecFileResult, exit, env, cwd, platform } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, remove, removeAll, copyFile } from "std/fs";
import { sleepAsync } from "std/core/promise";
import { spawn as spawnChild, ChildProcess, ChildStream } from "std/process/child";

function slashes(p: string): string {
	return p.replaceAll("\\", "/");
}

const ROOT = slashes(cwd());

function resolveMsc(): string {
	const explicit = slashes(env.get("MSC"));
	if (explicit != "") {
		if (explicit.indexOf("/") < 0) return explicit;
		return explicit.startsWith("/") || explicit.indexOf(":") >= 0 ? explicit : `${ROOT}/${explicit}`;
	}
	if (exists("./msc") || exists("./msc.exe")) return `${ROOT}/msc`;
	return "msc";
}

const MSC = resolveMsc();
env.set("NO_COLOR", "1");
const FIXTURES = `${ROOT}/src/test/hcr/fixtures`;
const STD_HOST = `${ROOT}/std/hcr/host.cms`;
const TMP = `${ROOT}/out/hcr`;

function lines(text: string): string[] {
	const out: string[] = [];
	for (const raw of text.split("\n")) out.push(raw.endsWith("\r") ? raw.slice(0, raw.length - 1) : raw);
	return out;
}

function both(r: ExecFileResult): string {
	return r.output + r.errorOutput;
}

function succeeded(r: ExecFileResult): boolean {
	return r.started && r.pipeOk && r.exitCode == 0 && r.signal == 0;
}

function read(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : "";
}

function put(path: string, content: string): void {
	if (!writeFile(path, content).ok) {
		console.log(`FAIL hcrRunner: cannot write ${path}`);
		exit(1);
	}
}

function copy(from: string, to: string): void {
	if (!copyFile(from, to).ok) {
		console.log(`FAIL hcrRunner: cannot copy ${from} -> ${to}`);
		exit(1);
	}
}

function failWith(tag: string, why: string): void {
	console.log(`FAIL ${tag}: ${why}`);
	exit(1);
}

const PARKED: { name: string, card: string }[] = [
	{ name: "hcrModulePassReload", card: "inbox card 2026-10-06-hcr-ref-array-cell-owned-by-user-image.md" },
];

const SAN = env.get("MSHCR_SAN") == "1";
const SAN_DLL = "clang_rt.asan_dynamic-x86_64.dll";
let sanFlags = "";

function sanSetup(): void {
	if (sanFlags != "") return;
	sanFlags = " ";
	if (platform != "windows") return;
	const resource = slashes(execFileResult("clang", ["-print-resource-dir"], ROOT).output.trim());
	const shim = `${TMP}/asan-shim`;
	const gnu = `${shim}/lib/x86_64-w64-windows-gnu`;
	if (!exists(`${gnu}/libclang_rt.asan_dynamic.dll.a`)) {
		ensureDir(TMP);
		execFileResult("cmd", ["/c", "xcopy", "/E", "/I", "/Y", resource.replaceAll("/", "\\"), shim.replaceAll("/", "\\")], ROOT);
		ensureDir(gnu);
		copy(`${resource}/lib/windows/clang_rt.asan_dynamic-x86_64.lib`, `${gnu}/libclang_rt.asan_dynamic.a`);
		copy(`${resource}/lib/windows/clang_rt.asan_dynamic-x86_64.lib`, `${gnu}/libclang_rt.asan_dynamic.dll.a`);
		copy(`${resource}/lib/windows/clang_rt.asan_dynamic_runtime_thunk-x86_64.lib`, `${gnu}/libclang_rt.asan_dynamic_runtime_thunk.a`);
	}
	sanFlags = ` --target=x86_64-w64-mingw32 -resource-dir ${shim}`;
}

function sanRuntime(dir: string): void {
	if (platform != "windows") return;
	const resource = slashes(execFileResult("clang", ["-print-resource-dir"], ROOT).output.trim());
	copy(`${resource}/lib/windows/${SAN_DLL}`, `${dir}/${SAN_DLL}`);
}

const RUN_CAP_MS = 300000;

function capNotice(capMs: int32): string {
	return `hcr runner: msc run cut after ${capMs} ms`;
}

function boundedRun(dir: string, args: string[], capMs: int32): ExecFileResult {
	const started = spawnChild(MSC, args, { cwd: dir, mergeStderr: true });
	if (!started.ok) return execFileResult(MSC, args, dir);
	const child = started.value;
	let text = "";
	let ended = false;
	const deadline = performance.now() + capMs;
	while (!ended && performance.now() < deadline) {
		const got = child.read(ChildStream.Stdout, 200);
		if (!got.ok) continue;
		if (got.value.ended) ended = true;
		else text += got.value.data;
	}
	const status = ended ? child.wait(30000) : child.kill();
	const done = ended && status.ok;
	if (!done) text += `\n${capNotice(capMs)}\n`;
	const result: ExecFileResult = {
		started: true,
		pipeOk: done,
		exitCode: status.ok ? status.value.code : -1,
		signal: status.ok ? status.value.signal : 0,
		output: text,
		errorOutput: "",
		startErrno: 0,
	};
	child.close();
	return result;
}

function msc(dir: string, args: string[], capMs: int32 = RUN_CAP_MS): ExecFileResult {
	if (args[0] == "run") return boundedRun(dir, args, capMs);
	if (!SAN || args[0] != "build") return execFileResult(MSC, args, dir);
	sanSetup();
	const full: string[] = [];
	for (const arg of args) full.push(arg);
	full.push("--cc=clang");
	full.push(`--passC=-O0 -g -fsanitize=address -DMS_SLAB_MAX=0 -Wno-error=incompatible-pointer-types${sanFlags}`);
	full.push(`--passL=-fsanitize=address -pthread${sanFlags}`);
	return execFileResult(MSC, full, dir);
}

// Build that must succeed: its log is printed before the verdict when it does not.
function mustBuild(tag: string, dir: string, args: string[], why: string): string {
	const r = msc(dir, args);
	if (!succeeded(r)) {
		console.log(both(r));
		failWith(tag, why);
	}
	return both(r);
}

function need(tag: string, ok: boolean, why: string): void {
	if (!ok) failWith(tag, why);
}

function freshDir(path: string): string {
	removeAll(path);
	ensureDir(path);
	return path;
}

function sharedLibraryExt(): string {
	if (platform == "windows") return ".dll";
	if (platform == "darwin") return ".dylib";
	return ".so";
}

function coreLinkClang(): void {
	const tag = "hcrCoreLinkClang";
	if (platform == "windows") {
		console.log(`skip ${tag}: clang on Windows targets msvc, which --hcr does not build`);
		return;
	}
	if (!succeeded(execFileResult("clang", ["--version"], ROOT))) {
		console.log(`skip ${tag}: no clang on PATH`);
		return;
	}
	const work = freshDir(`${TMP}/clang`);
	copy(`${FIXTURES}/app.ms`, `${work}/app.ms`);
	copy(`${FIXTURES}/logic.ms`, `${work}/logic.ms`);
	mustBuild(tag, work, ["build", "app.ms", "--hcr", "--output=module.hcr", "--cc=clang"], "cold build with --cc=clang failed");
	need(tag, exists(`${work}/module.core${sharedLibraryExt()}`), `core image module.core${sharedLibraryExt()} missing`);
	console.log(`ok   ${tag}`);
}


function moduleAbi(): void {
	const tag = "hcrModuleObjectCache";
	const work = freshDir(`${TMP}/work`);
	copy(`${FIXTURES}/app.ms`, `${work}/app.ms`);
	copy(`${FIXTURES}/logic.ms`, `${work}/logic.ms`);
	const hcrBuild = ["build", "app.ms", "--hcr", "--verbose", "--output=module.hcr"];
	const quietBuild = ["build", "app.ms", "--hcr", "--output=module.hcr"];
	const bundle = `${work}/module.hcr.hcrabi`;

	mustBuild(tag, work, hcrBuild, "cold build failed");
	need(tag, exists(`${work}/module.core${sharedLibraryExt()}`), `core image module.core${sharedLibraryExt()} missing`);
	need(tag, exists(bundle), "HCR ABI bundle missing");

	copy(`${FIXTURES}/logicBodyEdit.ms`, `${work}/logic.ms`);
	const edit = mustBuild(tag, work, hcrBuild, "body-edit build failed");
	let supplied = 0;
	let logicSupplied = false;
	let appSupplied = false;
	let appCached = false;
	for (const line of lines(edit)) {
		const t = line.trim();
		if (line.startsWith("    cc ")) {
			supplied = supplied + 1;
			if (line.contains("logic_x_ms")) logicSupplied = true;
			if (line.contains("app_x_ms")) appSupplied = true;
		}
		if (line != t && t.startsWith("stored ")) {
			supplied = supplied + 1;
			if (t.endsWith("logic.ms")) logicSupplied = true;
			if (t.endsWith("app.ms")) appSupplied = true;
		}
		if (line != t && t.startsWith("cached ") && t.endsWith("app.ms")) appCached = true;
	}
	need(tag, supplied == 1, `body edit compiled or restored ${supplied} modules, expected 1`);
	need(tag, logicSupplied, "logic object was neither compiled nor restored");
	need(tag, !appSupplied, "unchanged app object was compiled or restored");
	need(tag, appCached, "unchanged app object was not reported cached");
	need(tag, exists(`${work}/module.hcr`), "linked HCR image missing");

	const before = read(`${work}/module.hcr`);
	put(bundle, "{broken\n");
	const corrupt = msc(work, quietBuild);
	need(tag, !succeeded(corrupt), "corrupt current ABI bundle was accepted");
	need(tag, read(`${work}/module.hcr`) == before, "corrupt bundle replaced current image");
	console.log("ok   hcrModuleAbi");
}

function linkInputKeys(dir: string): string[] {
	const cache = `${dir}/out/debug/.cache`;
	const keys: string[] = [];
	for (const e of readDir(cache)) {
		if (!e.startsWith("link.") || !e.endsWith(".cache")) continue;
		const inputs: string[] = [e];
		for (const line of lines(read(`${cache}/${e}`))) {
			if (!line.startsWith("outputHash:")) inputs.push(line);
		}
		keys.push(inputs.join("\n"));
	}
	return keys;
}

function firstWarmBuild(): void {
	const tag = "hcrFirstWarmBuild";
	const dir = freshDir(`${TMP}/firstWarm`);
	copy(`${FIXTURES}/app.ms`, `${dir}/app.ms`);
	copy(`${FIXTURES}/logic.ms`, `${dir}/logic.ms`);
	const build = ["build", "app.ms", "--hcr", "--output=module.hcr"];
	mustBuild(tag, dir, build, "cold build failed");
	const cold = linkInputKeys(dir);
	copy(`${FIXTURES}/logicBodyEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, build, "body-edit build failed");
	let relinked = 0;
	const changed: string[] = [];
	for (const key of linkInputKeys(dir)) {
		if (!cold.includes(key)) {
			relinked += 1;
			changed.push(key);
		}
	}
	need(tag, cold.length > 0, "the cold build left no link keys");
	if (relinked != 1) {
		for (const key of changed) {
			const name = key.split("\n")[0];
			let before = "(no cold entry)";
			for (const entry of cold) {
				if (entry.split("\n")[0] == name) before = entry;
			}
			console.log(`${tag}: ${name} changed\n--- cold\n${before}\n--- warm\n${key}`);
		}
	}
	need(tag, relinked == 1, `the first warm build relinked ${relinked} images, expected only logic's`);

	const plain = freshDir(`${TMP}/firstWarmPlain`);
	copy(`${FIXTURES}/app.ms`, `${plain}/app.ms`);
	copy(`${FIXTURES}/logic.ms`, `${plain}/logic.ms`);
	const plainBuild = ["build", "app.ms", "--verbose", "--output=app"];
	const globalCache = env.get("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	mustBuild(tag, plain, plainBuild, "cold plain build failed");
	copy(`${FIXTURES}/logicBodyEdit.ms`, `${plain}/logic.ms`);
	const warm = mustBuild(tag, plain, plainBuild, "plain body-edit build failed");
	env.set("MSC_NO_GLOBAL_CACHE", globalCache);
	let recompiled = 0;
	let reused = 0;
	for (const line of lines(warm)) {
		if (!line.trim().startsWith("@compile ")) continue;
		if (line.endsWith("(cached)")) reused += 1; else recompiled += 1;
	}
	need(tag, reused + recompiled > 0, "the first warm plain build reported no @compile object");
	need(tag, recompiled == 0, `the first warm plain build compiled ${recompiled} @compile objects again`);
	console.log(`ok   ${tag}`);
}

function timeReportsPhaseC(): void {
	const tag = "hcrTimeReportsPhaseC";
	const dir = freshDir(`${TMP}/timePhaseC`);
	copy(`${FIXTURES}/app.ms`, `${dir}/app.ms`);
	copy(`${FIXTURES}/logic.ms`, `${dir}/logic.ms`);
	const hcr = ["build", "app.ms", "--hcr", "--time", "--output=module.hcr"];
	const cold = mustBuild(tag, dir, hcr, "cold --hcr build failed");
	copy(`${FIXTURES}/logicBodyEdit.ms`, `${dir}/logic.ms`);
	const warm = mustBuild(tag, dir, hcr, "warm --hcr build failed");
	need(tag, cold.contains("phase C (codegen+compile)") && cold.contains("codegen: "), "a cold --hcr build printed no phase C");
	need(tag, warm.contains("phase C (codegen+compile)") && warm.contains("codegen: "), "a warm --hcr build printed no phase C");
	console.log(`ok   ${tag}`);
}

function emittedModuleC(dir: string, stem: string): string {
	const debug = `${dir}/out/debug`;
	for (const e of readDir(debug)) {
		if (!e.startsWith("_") && e.endsWith(`Z${stem}Oms.c`)) return read(`${debug}/${e}`);
	}
	return "";
}

function bundleSection(bundle: string, stem: string): string {
	const kept: string[] = [];
	let inside = false;
	for (const line of lines(bundle)) {
		if (line.startsWith("// --- Module: ")) inside = line.endsWith(`/${stem} ---`);
		if (inside) kept.push(line);
	}
	return kept.join("\n");
}

function localNames(): void {
	const tag = "hcrModuleLocalNames";
	const dir = freshDir(`${TMP}/localNames`);
	for (const f of ["app.ms", "a.ms", "b.ms", "tpl.ms"]) copy(`${FIXTURES}/localNames/${f}`, `${dir}/${f}`);
	const edits = ["a.ms", "aAsyncEdit.ms", "aTemplateEdit.ms"];
	const cOf: string[] = [];
	const jsOf: string[] = [];
	for (const edit of edits) {
		copy(`${FIXTURES}/localNames/${edit}`, `${dir}/a.ms`);
		removeAll(`${dir}/out`);
		mustBuild(tag, dir, ["build", "app.ms", "--emit=c"], `C emission failed with ${edit}`);
		cOf.push(emittedModuleC(dir, "b"));
		mustBuild(tag, dir, ["build", "app.ms", "--target=js", "--output=bundle.js"], `JS emission failed with ${edit}`);
		jsOf.push(bundleSection(read(`${dir}/bundle.js`), "b"));
	}
	for (let i = 1; i < edits.length; i += 1) {
		need(tag, cOf[i] == cOf[0], `${edits[i]} changed the C of the untouched module b`);
		need(tag, jsOf[i] == jsOf[0], `${edits[i]} changed the JS of the untouched module b`);
	}
	console.log("ok   hcrModuleLocalNames");
}

interface WatchStep {
	file: string;
	target: string;
	warm: boolean;
	fails: boolean;
}

function cFilesIn(dir: string): string[] {
	const names: string[] = [];
	if (!exists(dir)) return names;
	for (const e of readDir(dir)) {
		if (e.endsWith(".c")) names.push(e);
	}
	names.sort();
	return names;
}

function partialRecheck(status: string): boolean {
	const at = status.indexOf("(checked ", 0);
	if (at < 0) return false;
	const counts = status.slice(at + 9, status.indexOf(",", at)).split("/");
	return counts.length == 2 && counts[0] != counts[1];
}

function watchWarm(): void {
	const tag = "hcrWatchWarm";
	const dir = freshDir(`${TMP}/watchWarm`);
	for (const f of readDir(`${FIXTURES}/watchWarm`)) copy(`${FIXTURES}/watchWarm/${f}`, `${dir}/${f}`);
	const steps: WatchStep[] = [
		{ file: "logicBody.ms", target: "logic.ms", warm: true, fails: false },
		{ file: "viewShift.ms", target: "view.ms", warm: true, fails: false },
		{ file: "logicError.ms", target: "logic.ms", warm: false, fails: true },
		{ file: "logicEmpty.ms", target: "logic.ms", warm: false, fails: true },
		{ file: "logicBody.ms", target: "logic.ms", warm: true, fails: false },
		{ file: "logicMap.ms", target: "logic.ms", warm: false, fails: false },
		{ file: "shapesBody.ms", target: "shapes.ms", warm: true, fails: false },
		{ file: "logicExport.ms", target: "logic.ms", warm: false, fails: false },
		{ file: "logicInt64.ms", target: "logic.ms", warm: false, fails: false },
		{ file: "logicOriginal.ms", target: "logic.ms", warm: false, fails: false },
		{ file: "boxHookBody.ms", target: "box.ms", warm: true, fails: false },
		{ file: "boxRunBody.ms", target: "box.ms", warm: true, fails: false },
		{ file: "boxCtor.ms", target: "box.ms", warm: true, fails: false },
		{ file: "boxOverride.ms", target: "box.ms", warm: false, fails: false },
		{ file: "boxNoHook.ms", target: "box.ms", warm: false, fails: false },
		{ file: "logicStd.ms", target: "logic.ms", warm: true, fails: false },
		{ file: "logicBody.ms", target: "logic.ms", warm: true, fails: false },
	];
	replayMatchesCold(tag, dir, `${FIXTURES}/watchWarm`, ["logic.ms", "view.ms", "shapes.ms", "box.ms"], steps);
	console.log("ok   hcrWatchWarm");
}

function watchGeneric(): void {
	const tag = "hcrWatchGeneric";
	const dir = copyAppAndLib("watchGeneric");
	const steps: WatchStep[] = [
		{ file: "logicBody.ms", target: "logic.ms", warm: true, fails: false },
		{ file: "logicString.ms", target: "logic.ms", warm: false, fails: false },
		{ file: "logicStringBody.ms", target: "logic.ms", warm: true, fails: false },
		{ file: "logicTag.ms", target: "logic.ms", warm: false, fails: false },
	];
	replayMatchesCold(tag, `${dir}/app`, `${FIXTURES}/watchGeneric/app`, ["logic.ms"], steps);
	console.log("ok   hcrWatchGeneric");
}

function copyAppAndLib(fixture: string): string {
	const dir = freshDir(`${TMP}/${fixture}`);
	for (const sub of ["app", "lib"]) {
		ensureDir(`${dir}/${sub}`);
		for (const f of readDir(`${FIXTURES}/${fixture}/${sub}`)) copy(`${FIXTURES}/${fixture}/${sub}/${f}`, `${dir}/${sub}/${f}`);
	}
	return dir;
}

function newInstance(): void {
	reloadsNewTypeEdit("hcrNewInstance", "newInstance", "HCR-NEW", "a new generic instance over a new app type did not reload into the running app");
}

function privateHelper(): void {
	reloadsNewTypeEdit("hcrPrivateHelper", "privateHelper", "HCR-PRIVATE", "a generic body calling private functions of its module did not build or reload in the image that uses it");
}

const VALUE_APP = "import { value } from \"./logic\";

@exportName(\"hcrValue\")
export function hcrValue(): int32 {
	return value();
}
";

function returns(name: string, shown: int32): string {
	return `export function ${name}(): int32 {
	return ${shown};
}
`;
}

// A module that joins or leaves the project has no manifest on the other side of the comparison.
function addedModule(): void {
	const tag = "hcrAddedModule";
	const dir = freshDir(`${TMP}/addedModule`);
	const build = ["build", "app.ms", "--hcr", "--output=module.hcr"];
	put(`${dir}/app.ms`, VALUE_APP);
	put(`${dir}/logic.ms`, returns("value", 1));
	put(`${dir}/words.ms`, returns("word", 2));
	mustBuild(tag, dir, build, "the first build failed");
	put(`${dir}/logic.ms`, "import { word } from \"./words\";
export function value(): int32 {
	return word();
}
");
	const added = msc(dir, build);
	if (!succeeded(added) || both(added).indexOf("HCR reload module: module added (words)") < 0) {
		console.log(both(added));
		failWith(tag, "a build that adds a module to an existing bundle did not report it as added");
	}
	put(`${dir}/logic.ms`, returns("value", 1));
	const removed = msc(dir, build);
	if (!succeeded(removed) || both(removed).indexOf("HCR reload dependents: module removed (words)") < 0) {
		console.log(both(removed));
		failWith(tag, "a build that drops a module from an existing bundle did not report it as removed");
	}
	console.log(`ok   ${tag}`);
}

function lastEntry(dir: string): string {
	let last = "";
	for (const name of readDir(dir)) {
		if (name > last) last = name;
	}
	return last == "" ? "" : `${dir}/${last}`;
}

function androidNdkBin(): string {
	let ndk = slashes(env.get("ANDROID_NDK_HOME"));
	for (const sdk of [slashes(env.get("ANDROID_HOME")), `${slashes(env.get("LOCALAPPDATA"))}/Android/Sdk`]) {
		if (ndk == "" && exists(`${sdk}/ndk`)) ndk = lastEntry(`${sdk}/ndk`);
	}
	if (ndk == "") return "";
	const host = lastEntry(`${ndk}/toolchains/llvm/prebuilt`);
	return host == "" ? "" : `${host}/bin`;
}

// Android loads images the way Linux does (soname on the core, $ORIGIN on the modules); a host
// that owns the entry point starts the engine through msHcrEngineStartLibrary; and API 26 is
// below the level where bionic has posix_spawn, which the engine's core image compiles against.
function androidImages(): void {
	const tag = "hcrAndroidImages";
	const bin = androidNdkBin();
	const exe = platform == "windows" ? ".exe" : "";
	if (bin == "" || !exists(`${bin}/clang${exe}`)) {
		console.log(`skip ${tag}: no Android NDK (ANDROID_NDK_HOME, or ndk/ under ANDROID_HOME)`);
		return;
	}
	for (const cpu of ["x86_64", "aarch64"]) {
		const dir = freshDir(`${TMP}/android/${cpu}`);
		put(`${dir}/app.ms`, "import { reload } from \"std/hcr\";
import { value } from \"./logic\";

@exportName(\"hcrValue\")
export function hcrValue(): int32 {
	reload();
	return value();
}
");
		put(`${dir}/logic.ms`, returns("value", 1));
		const triple = `--target=${cpu}-linux-android26`;
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", "--os=android", `--cpu=${cpu}`, "--app=lib", `--cc=${bin}/clang${exe}`,
			`--passC=${triple}`, `--passL=${triple}`, "--passL=--driver-mode=g++", "--output=libapp.so"], `the ${cpu} images did not build for API 26`);
		const core = both(execFileResult(`${bin}/llvm-readelf${exe}`, ["-d", "libapp.core.so"], dir));
		const image = both(execFileResult(`${bin}/llvm-readelf${exe}`, ["-d", "libapp.logic.so"], dir));
		const exported = both(execFileResult(`${bin}/llvm-nm${exe}`, ["-D", "--defined-only", "libapp.core.so"], dir));
		need(tag, core.indexOf("soname: [libapp.core.so]") >= 0, `${cpu}: the core image has no soname libapp.core.so`);
		need(tag, image.indexOf("[libapp.core.so]") >= 0 && image.indexOf("[$ORIGIN]") >= 0, `${cpu}: a module image does not find the core beside it`);
		need(tag, exported.indexOf(" msHcrEngineStartLibrary") >= 0 && exported.indexOf(" msHcrLaunch") >= 0, `${cpu}: the core image does not export the library start`);
	}
	console.log(`ok   ${tag}`);
}

function settleSecond(): void {
	await sleepAsync(1100);
}

// The entry image is the output the project record names, and an edit of another module leaves it
// alone. A build that starts in the second of that save writes no record, so the record of the
// build before it has to go: it would call the output current once the module is restored.
function sameSecondEdit(): void {
	const tag = "hcrSameSecondEdit";
	const build = ["build", "app.ms", "--hcr", "--output=module.hcr"];
	for (const nested of [false, true]) {
		const dir = freshDir(`${TMP}/sameSecond${nested ? "Nested" : ""}`);
		const edited = nested ? "deep" : "value";
		const file = `${dir}/${nested ? "deep" : "logic"}.ms`;
		put(`${dir}/app.ms`, VALUE_APP);
		if (nested) put(`${dir}/logic.ms`, "import { deep } from \"./deep\";
export function value(): int32 {
	return deep();
}
");
		put(file, returns(edited, 1));
		settleSecond();
		mustBuild(tag, dir, build, "the first build failed");
		put(file, returns(edited, 2));
		mustBuild(tag, dir, build, "the build in the second of the save failed");
		settleSecond();
		put(file, returns(edited, 1));
		const restored = mustBuild(tag, dir, build, "the build after restoring the module failed");
		if (restored.indexOf("Up to date") >= 0) {
			console.log(restored);
			failWith(tag, `restoring ${file} was called up to date on the record of the first build, while its image holds the edit in between`);
		}
	}
	console.log(`ok   ${tag}`);
}

function subdirModule(): void {
	const tag = "hcrSubdirModule";
	const dir = freshDir(`${TMP}/subdir`);
	ensureDir(`${dir}/lib`);
	copy(`${FIXTURES}/subdir/app.ms`, `${dir}/app.ms`);
	copy(`${FIXTURES}/subdir/lib/util.ms`, `${dir}/lib/util.ms`);
	copy(`${FIXTURES}/subdir/utilEdit.ms`, `${dir}/edit.txt`);
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-SUB ")) seen.push(line);
	}
	const want = ["HCR-SUB start 7", "HCR-SUB reloaded true 8"];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "a module in a subdirectory did not load or reload under msc run --hcr");
	}
	console.log(`ok   ${tag}`);
}

function runBound(): void {
	const tag = "hcrRunBound";
	const cases = [
		{ fixture: "typeError.txt", capMs: 30000, seen: "type error" },
		{ fixture: "parseError.txt", capMs: 30000, seen: "Unexpected token" },
	];
	for (const c of cases) {
		const dir = freshDir(`${TMP}/runBound_${c.fixture}`);
		copy(`${FIXTURES}/runBound/${c.fixture}`, `${dir}/app.ms`);
		const t0 = performance.now();
		const ran = msc(dir, ["run", "--hcr", "app.ms"], c.capMs);
		const took = performance.now() - t0;
		if (succeeded(ran) || !both(ran).contains(capNotice(c.capMs)) || !both(ran).contains(c.seen) || took > c.capMs + 40000) {
			console.log(both(ran));
			failWith(tag, `${c.fixture}: msc run --hcr was not cut at ${c.capMs} ms with its output kept (took ${Math.round(took)} ms)`);
		}
	}
	console.log(`ok   ${tag}`);
}

function reloadsNewTypeEdit(tag: string, fixture: string, prefix: string, why: string): void {
	const dir = copyAppAndLib(fixture);
	copy(`${dir}/app/logicTag.ms`, `${dir}/app/edit.txt`);
	mustBuild(tag, `${dir}/app`, ["build", "app.ms", "--hcr", "--output=out/built/app"], why);
	const ran = msc(`${dir}/app`, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith(`${prefix} `)) seen.push(line);
	}
	const want = [`${prefix} start 9`, `${prefix} reloaded 15`];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, why);
	}
	console.log(`ok   ${tag}`);
}

function replayMatchesCold(tag: string, dir: string, fixture: string, restored: string[], steps: WatchStep[]): void {
	let replay = "";
	for (const s of steps) replay = replay + `${s.file} ${s.target}\n`;
	put(`${dir}/replay.txt`, replay);
	const watched = msc(dir, ["build", "app.ms", "--hcr", "--watch-replay=replay.txt", "--emit=c"]);
	const statuses: string[] = [];
	for (const line of lines(both(watched))) {
		if (line.startsWith("watch: build ")) statuses.push(line);
	}
	if (!succeeded(watched) || statuses.length != steps.length + 1) {
		console.log(both(watched));
		failWith(tag, `the watch replay reported ${statuses.length} builds, expected ${steps.length + 1}`);
	}

	for (const f of restored) copy(`${fixture}/${f}`, `${dir}/${f}`);
	const debug = `${dir}/out/debug`;
	for (let n = 0; n <= steps.length; n += 1) {
		const step: WatchStep | null = n > 0 ? steps[n - 1] : null;
		if (step != null) copy(`${dir}/${step!.file}`, `${dir}/${step!.target}`);
		for (const f of cFilesIn(debug)) removeAll(`${debug}/${f}`);
		const cold = msc(dir, ["build", "app.ms", "--hcr", "--emit=c"]);
		const label = step != null ? `step ${n} (${step!.file})` : "the first build";
		const status = statuses[n];
		if (step != null && step!.fails) {
			need(tag, !succeeded(cold) && status.contains(" failed "), `${label} should fail warm and cold: ${status}`);
			continue;
		}
		if (!succeeded(cold)) {
			console.log(both(cold));
			failWith(tag, `the cold build of ${label} failed`);
		}
		need(tag, !status.contains(" failed "), `${label} failed warm: ${status}`);
		const warmFiles = cFilesIn(`${debug}/watch${n}`);
		const coldFiles = cFilesIn(debug);
		need(tag, warmFiles.join(",") == coldFiles.join(","), `${label} emitted ${warmFiles.length} files warm, ${coldFiles.length} cold`);
		for (const f of coldFiles) {
			need(tag, read(`${debug}/watch${n}/${f}`) == read(`${debug}/${f}`), `${label}: ${f} differs from a cold build`);
		}
		if (step != null && step!.warm) {
			need(tag, status.contains(" built ") && partialRecheck(status), `${label} did not stay warm: ${status}`);
		}
	}
}

function arrayOwner(): void {
	const tag = "hcrArrayOwner";
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	const sources = ["app.ms", "first.ms", "second.ms", "logic.ms", "logicEdit.ms"];
	const dir = freshDir(`${TMP}/arrayOwner`);
	for (const f of sources) copy(`${FIXTURES}/arrayOwner/${f}`, `${dir}/${f}`);
	copy(STD_HOST, `${dir}/host.cms`);
	put(`${dir}/replay.txt`, "logicEdit.ms logic.ms\n");
	const watched = msc(dir, ["build", "app.ms", "--hcr", "--watch-replay=replay.txt", `--output=run/module${ext}`]);
	const statuses: string[] = [];
	for (const line of lines(both(watched))) {
		if (line.startsWith("watch: build ")) statuses.push(line);
	}
	if (!succeeded(watched) || statuses.length != 2 || statuses[0].contains(" failed ") || statuses[1].contains(" failed ")) {
		console.log(both(watched));
		failWith(tag, "the warm replay of modules sharing another module's struct arrays did not build");
	}
	need(tag, partialRecheck(statuses[1]), `the edit of logic did not stay warm: ${statuses[1]}`);
	mustBuild(tag, dir, ["build", "host.cms", `--output=${exe}`], "thin host build failed");
	const warm = execFileResult(`${dir}/${exe}`, ["run", "module"], dir);
	need(tag, succeeded(warm) && lines(both(warm)).includes("HCR-ARRAY first 40"), `the replayed images ran: ${both(warm)}`);

	const cold = freshDir(`${TMP}/arrayOwnerCold`);
	for (const f of sources) copy(`${FIXTURES}/arrayOwner/${f}`, `${cold}/${f}`);
	copy(`${FIXTURES}/arrayOwner/logicEdit.ms`, `${cold}/logic.ms`);
	mustBuild(tag, cold, ["build", "app.ms", "--hcr", `--output=run/module${ext}`], "the cold HCR build of the edited state failed");
	const coldRun = execFileResult(`${dir}/${exe}`, ["run", "module"], cold);
	need(tag, succeeded(coldRun) && lines(both(coldRun)).includes("HCR-ARRAY first 40"), `the cold images ran: ${both(coldRun)}`);

	const reloaded = freshDir(`${TMP}/arrayOwnerReload`);
	for (const f of sources) copy(`${FIXTURES}/arrayOwner/${f}`, `${reloaded}/${f}`);
	mustBuild(tag, reloaded, ["build", "app.ms", "--hcr", `--output=g1/module${ext}`], "the first generation did not build");
	copy(`${FIXTURES}/arrayOwner/logicEdit.ms`, `${reloaded}/logic.ms`);
	mustBuild(tag, reloaded, ["build", "app.ms", "--hcr", `--output=g2/module${ext}`], "the edited generation did not build");
	ensureDir(`${reloaded}/run`);
	for (const image of [`module${ext}`, `module.core${ext}`, `module.first${ext}`, `module.second${ext}`, `module.logic${ext}`, `module${ext}.hcrabi`]) {
		copy(`${reloaded}/g1/${image}`, `${reloaded}/run/${image}`);
	}
	const ran = execFileResult(`${dir}/${exe}`, ["run", "module"], reloaded);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-ARRAY ")) seen.push(line);
	}
	if (!succeeded(ran) || seen.join("\n") != ["HCR-ARRAY first 20", "HCR-ARRAY reloaded 40"].join("\n")) {
		console.log(both(ran));
		failWith(tag, "reloading logic did not keep the other modules' struct array operations");
	}
	console.log(`ok   ${tag}`);
}

function indirect(): void {
	const tag = "hcrIndirect";
	const dir = freshDir(`${TMP}/indirect`);
	for (const f of ["app.ms", "logic.ms", "shapes.ms", "host.ms", "hostCalls.h"]) copy(`${FIXTURES}/indirect/${f}`, `${dir}/${f}`);

	if (platform != "windows" && platform != "linux" && platform != "darwin") {
		console.log(`skip ${tag}: no native fixture host adapter for ${platform}`);
		return;
	}
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g1/module${ext}`], "HCR image link failed");
	for (const image of [`module${ext}`, `module.core${ext}`, `module.logic${ext}`, `module.shapes${ext}`]) {
		need(tag, exists(`${dir}/g1/${image}`), `per-module image g1/${image} missing`);
	}
	copy(`${FIXTURES}/indirect/logicBodyEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g2/module${ext}`], "HCR rebuild after the logic edit failed");
	copy(`${FIXTURES}/indirect/logicExportEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g3/module${ext}`], "HCR rebuild after the logic export edit failed");
	copy(`${FIXTURES}/indirect/logicBindingEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g4/module${ext}`], "HCR rebuild after the function signature edit failed");
	mustBuild(tag, dir, ["build", "host.ms", `--output=${exe}`], "host build failed");
	const called = execFileResult(`${dir}/${exe}`,
		[`g1/module.logic${ext}`, `g1/module.shapes${ext}`, `g1/module${ext}`, "--",
			`g2/module.logic${ext}`, `g3/module.logic${ext}`, `g4/module.logic${ext}`], dir);
	const want = [
		"HCR-HOST gen1 hcrIndirectValue -> 37",
		"HCR-HOST gen1 hcrShapeValue -> 9",
		"HCR-HOST gen1 hcrErrorValue -> 1",
		"HCR-HOST gen1 hcrTickValue -> 1",
		`HCR-HOST bindings module${ext} -> logic match`,
		"HCR-HOST staged logic -> 1",
		"HCR-HOST staged hcrIndirectValue -> 37",
		`HCR-HOST reloaded g2/module.logic${ext}`,
		"HCR-HOST gen2 hcrIndirectValue -> 163",
		"HCR-HOST gen2 hcrShapeValue -> 9",
		"HCR-HOST gen2 hcrErrorValue -> 1",
		"HCR-HOST gen2 hcrTickValue -> 11",
		"HCR-HOST rolled back logic",
		"HCR-HOST rollback hcrIndirectValue -> 37",
		"HCR-HOST rollback hcrTickValue -> 12",
		`HCR-HOST bindings module${ext} -> logic match`,
		"HCR-HOST staged logic -> 1",
		"HCR-HOST staged hcrIndirectValue -> 37",
		`HCR-HOST reloaded g3/module.logic${ext}`,
		"HCR-HOST gen2 hcrIndirectValue -> 37",
		"HCR-HOST gen2 hcrShapeValue -> 9",
		"HCR-HOST gen2 hcrErrorValue -> 1",
		"HCR-HOST gen2 hcrTickValue -> 13",
		"HCR-HOST finalized logic",
		`HCR-HOST bindings module${ext} -> logic differ`,
		`HCR-HOST rejected g4/module.logic${ext}`,
		"HCR-HOST rejection hcrIndirectValue -> 37",
		"HCR-HOST rejection hcrTickValue -> 14",
	];
	if (!succeeded(called) || lines(both(called).trim()).join("\n") != want.join("\n")) {
		console.log(both(called));
		failWith(tag, "the host binding, stage, commit, rollback and finalize transitions differed");
	}
	console.log("ok   hcrIndirect");
}


function engine(): void {
	const tag = "hcrEngine";
	const dir = freshDir(`${TMP}/engine`);
	for (const f of ["app.ms", "handlerMisuse.ms"]) copy(`${FIXTURES}/engine/${f}`, `${dir}/${f}`);
	copy(STD_HOST, `${dir}/host.cms`);
	const misuse = msc(dir, ["build", "handlerMisuse.ms", "--hcr", "--emit=c"]);
	need(tag, !succeeded(misuse), "misused reload handlers were accepted");
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	const generations = [
		["logic.ms", "lifecycle.ms", "g1"],
		["logicBodyEdit.ms", "lifecycle.ms", "g2"],
		["logicExportEdit.ms", "lifecycle.ms", "g3"],
		["logicLayoutEdit.ms", "lifecycle.ms", "g4"],
		["logic.ms", "lifecycleThrowingEdit.ms", "g5"],
		["logic.ms", "lifecycleLayoutEdit.ms", "g6"],
	];
	for (const g of generations) {
		copy(`${FIXTURES}/indirect/${g[0]}`, `${dir}/logic.ms`);
		copy(`${FIXTURES}/engine/${g[1]}`, `${dir}/lifecycle.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=${g[2]}/module${ext}`], `HCR build of ${g[0]} + ${g[1]} failed`);
	}
	mustBuild(tag, dir, ["build", "host.cms", `--output=${exe}`], "thin host build failed");
	ensureDir(`${dir}/run`);
	for (const image of [`module${ext}`, `module.core${ext}`, `module.logic${ext}`, `module.lifecycle${ext}`, `module${ext}.hcrabi`]) {
		copy(`${dir}/g1/${image}`, `${dir}/run/${image}`);
	}
	const ran = execFileResult(`${dir}/${exe}`, ["run", "module"], dir);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-ENGINE ")) seen.push(line);
	}
	const want = [
		"HCR-ENGINE start: value 10 tick 1 version 1",
		"HCR-ENGINE unchanged: no change",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE body edit: reloaded logic",
		"HCR-ENGINE after body edit: value 73 tick 11 version 1",
		"HCR-ENGINE truncated image: pending logic",
		"HCR-ENGINE same truncated image: pending logic",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE complete image: reloaded logic",
		"HCR-ENGINE after complete image: value 10 tick 12 version 1",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE lifecycle rebuilt: reloaded lifecycle",
		"HCR-ENGINE probe from the first generation: instanceof true true scaled 70",
		"HCR-ENGINE lifecycle v1: destroy probe 8",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v2: after reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE after-reload handler throws: rejected lifecycle",
		"HCR-ENGINE after rollback: value 10 tick 13 version 1",
		"HCR-ENGINE probe after rollback: instanceof true true scaled 70",
		"HCR-ENGINE lifecycle v1: destroy probe 8",
		"HCR-ENGINE lifecycle v1: destroy probe 7",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE handler recovery: reloaded lifecycle",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE added export, app not rebuilt: reloaded logic",
		"HCR-ENGINE after added export: value 10 tick 14 version 1",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE added global: reloaded logic",
		"HCR-ENGINE after added global: value 10 tick 15 version 1",
		"HCR-ENGINE lifecycle v1: before reload",
		"HCR-ENGINE lifecycle v1: after reload",
		"HCR-ENGINE class layout changed: reloaded lifecycle",
		"HCR-ENGINE after class layout change: value 10 tick 16 version 1",
		"HCR-ENGINE core changed: restart required",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "the engine did not produce the expected reload outcomes");
	}
	console.log("ok   hcrEngine");
}

function asyncLoop(): void {
	const tag = "hcrAsyncLoop";
	const dir = freshDir(`${TMP}/asyncLoop`);
	copy(`${FIXTURES}/asyncLoop/app.ms`, `${dir}/app.ms`);
	copy(STD_HOST, `${dir}/host.cms`);
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	for (const g of [["logic.ms", "g1"], ["logicBodyEdit.ms", "g2"]]) {
		copy(`${FIXTURES}/indirect/${g[0]}`, `${dir}/logic.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=${g[1]}/module${ext}`], `HCR build of ${g[0]} failed`);
	}
	mustBuild(tag, dir, ["build", "host.cms", `--output=${exe}`], "thin host build failed");
	ensureDir(`${dir}/run`);
	for (const image of [`module${ext}`, `module.core${ext}`, `module.logic${ext}`, `module${ext}.hcrabi`]) {
		copy(`${dir}/g1/${image}`, `${dir}/run/${image}`);
	}
	const ran = execFileResult(`${dir}/${exe}`, ["run", "module"], dir);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-ASYNC ")) seen.push(line);
	}
	const want = [
		"HCR-ASYNC frame 0: no change value 10",
		"HCR-ASYNC frame 1: reloaded value 73",
		"HCR-ASYNC frame 2: no change value 73",
		"HCR-ASYNC done 3",
	];
	if (seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "an async frame loop did not run to its end under the host");
	}
	need(tag, ran.started && ran.pipeOk && ran.exitCode == 1 && ran.signal == 0,
		`an unhandled rejection left the host with exit ${ran.exitCode}`);
	console.log(`ok   ${tag}`);
}

function liftNames(): void {
	const tag = "hcrLiftNames";
	const dir = freshDir(`${TMP}/liftNames`);
	for (const f of ["app.ms", "logic.ms"]) copy(`${FIXTURES}/liftNames/${f}`, `${dir}/${f}`);
	copy(STD_HOST, `${dir}/host.cms`);
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=run/module${ext}`], "lifted module variables named with '$' did not build");
	mustBuild(tag, dir, ["build", "host.cms", `--output=${exe}`], "thin host build failed");
	const ran = execFileResult(`${dir}/${exe}`, ["run", "module"], dir);
	if (!succeeded(ran) || !both(ran).contains("HCR-LIFT hits 3 no change")) {
		console.log(both(ran));
		failWith(tag, "a lifted '$' variable or a top-level '||' temporary lost its value");
	}
	console.log(`ok   ${tag}`);
}

function liftKinds(): void {
	const tag = "hcrLiftKinds";
	const dir = freshDir(`${TMP}/liftKinds`);
	copy(`${FIXTURES}/liftKinds/app.ms`, `${dir}/app.ms`);
	copy(STD_HOST, `${dir}/host.cms`);
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	for (const g of [["logic.ms", "g1"], ["logicBodyEdit.ms", "g2"]]) {
		copy(`${FIXTURES}/liftKinds/${g[0]}`, `${dir}/logic.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=${g[1]}/module${ext}`], `HCR build of liftKinds/${g[0]} failed`);
	}
	mustBuild(tag, dir, ["build", "host.cms", `--output=${exe}`], "thin host build failed");
	ensureDir(`${dir}/run`);
	for (const image of [`module${ext}`, `module.core${ext}`, `module.logic${ext}`, `module${ext}.hcrabi`]) {
		copy(`${dir}/g1/${image}`, `${dir}/run/${image}`);
	}
	const ran = execFileResult(`${dir}/${exe}`, ["run", "module"], dir);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-KINDS ")) seen.push(line);
	}
	const want = [
		"HCR-KINDS before: v1 n1,n2 box 3 pair 4 seen 2 calls 2 parsed true",
		"HCR-KINDS reload: reloaded",
		"HCR-KINDS after: v2 n1,n2 box 3 pair 4 seen 2 calls 2 parsed true",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "module state of array, struct, class, nullable, Map or Result type did not survive a body reload");
	}
	console.log(`ok   ${tag}`);
}

function runCommand(): void {
	const tag = "hcrRun";
	const globalCache = env.get("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	for (const via of [false, true]) {
		const dir = freshDir(`${TMP}/run${via ? "Via" : ""}`);
		copy(`${FIXTURES}/run/app.ms`, `${dir}/app.ms`);
		if (via) {
			copy(`${FIXTURES}/run/via.ms`, `${dir}/via.ms`);
			put(`${dir}/app.ms`, read(`${dir}/app.ms`).replace(`from "./logic"`, `from "./via"`));
		}
		copy(`${FIXTURES}/indirect/logic.ms`, `${dir}/logic.ms`);
		copy(`${FIXTURES}/indirect/logicBodyEdit.ms`, `${dir}/edit.txt`);
		const copies = `${dir}/out/hcr/.hcr`;
		const ended = `${copies}/999999998`;
		const alive = `${copies}/${platform == "windows" ? "4" : "1"}`;
		const foreign = `${copies}/notARun`;
		const pastInt64 = `${copies}/18446744073709551616`;
		for (const d of [`${ended}/core`, alive, foreign, pastInt64]) ensureDir(d);
		for (const f of [`${ended}/core/app.core${sharedLibraryExt()}`, `${alive}/keep.txt`, `${foreign}/keep.txt`, `${pastInt64}/keep.txt`]) put(f, "x");
		const ran = msc(dir, ["run", "--hcr", "app.ms"]);
		const seen: string[] = [];
		for (const line of lines(both(ran))) {
			if (line.startsWith("HCR-RUN ")) seen.push(line);
		}
		const want = ["HCR-RUN start value 10", "HCR-RUN reloaded logic value 73"];
		if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
			console.log(both(ran));
			env.set("MSC_NO_GLOBAL_CACHE", globalCache);
			failWith(tag, `msc run --hcr${via ? " (logic imported through via.ms)" : ""} did not rebuild the edited module alone into the running app`);
		}
		need(tag, !both(ran).contains("still open for writing"), "an in-place save waited out the writer limit");
		need(tag, !exists(ended), "the image copies of an ended run survived the next start");
		need(tag, exists(`${alive}/keep.txt`), "the start removed the copies of a live process");
		need(tag, exists(`${foreign}/keep.txt`), "the start removed a directory that is not a run");
		need(tag, exists(`${pastInt64}/keep.txt`), "the start removed a directory whose digits pass int64");
	}
	env.set("MSC_NO_GLOBAL_CACHE", globalCache);
	console.log(`ok   ${tag}`);
}

function stepCrash(): void {
	const tag = "hcrStepCrash";
	const dir = freshDir(`${TMP}/stepCrash`);
	for (const f of readDir(`${FIXTURES}/step`)) copy(`${FIXTURES}/step/${f}`, `${dir}/${f}`);
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("STEP ")) seen.push(line);
	}
	const want = [
		"STEP start 2",
		"STEP rolled back logic fatal then 2 frame=0",
		"STEP rolled back logic fault then 2 frame=0",
		"STEP rolled back logic exception then 2 frame=0",
		"STEP rolled back logic fatal then 2 frame=0",
		"STEP rolled back logic fatal then 2 frame=0",
		"STEP reloaded 3",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "a crash inside step() did not roll back to the previous generation and keep running");
	}
	console.log(`ok   ${tag}`);
}

function reloadLines(output: string): string[] {
	const seen: string[] = [];
	for (const line of lines(output)) {
		if (line.startsWith("HCR reload module:")) seen.push(line);
	}
	return seen;
}

function unchangedObjectKeepsImage(): void {
	const tag = "hcrUnchangedObjectKeepsImage";
	const globalCache = env.get("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	if (platform != "windows") {
		const racy = freshDir(`${TMP}/unchangedRacyHeader`);
		for (const f of readDir(`${FIXTURES}/step`)) copy(`${FIXTURES}/step/${f}`, `${racy}/${f}`);
		need(tag, execFileResult("touch", ["-t", "203001010000", "hold.h"], racy).exitCode == 0, "cannot date hold.h into the future");
		put(`${racy}/replay.txt`, "crashIndex.txt logic.ms\n");
		const watched = mustBuild(tag, racy, ["build", "app.ms", "--hcr", "--watch-replay=replay.txt"], "the watch replay over a header dated in the future failed");
		const seen = reloadLines(watched);
		if (seen.join("\n") != "HCR reload module: implementation changed (logic)") {
			console.log(watched);
			failWith(tag, "an edit of logic.ms reloaded another module while a header the app includes was too new to record its object");
		}
	}
	const lost = freshDir(`${TMP}/unchangedLostRecord`);
	for (const f of readDir(`${FIXTURES}/step`)) copy(`${FIXTURES}/step/${f}`, `${lost}/${f}`);
	mustBuild(tag, lost, ["build", "app.ms", "--hcr"], "the first build failed");
	const cache = `${lost}/out/debug/.cache`;
	for (const f of readDir(cache)) {
		if (f.endsWith(".cfp")) remove(`${cache}/${f}`);
	}
	const rebuilt = mustBuild(tag, lost, ["build", "app.ms", "--hcr"], "the rebuild without object records failed");
	env.set("MSC_NO_GLOBAL_CACHE", globalCache);
	if (reloadLines(rebuilt).length != 0) {
		console.log(rebuilt);
		failWith(tag, "recompiling unchanged sources after their object records were lost reported a module as changed");
	}
	console.log(`ok   ${tag}`);
}

function stepJoinCrash(): void {
	const tag = "hcrStepJoinCrash";
	const dir = freshDir(`${TMP}/stepJoinCrash`);
	for (const f of ["hold.h", "logic.ms", "fixed.txt"]) copy(`${FIXTURES}/step/${f}`, `${dir}/${f}`);
	for (const f of readDir(`${FIXTURES}/stepJoin`)) copy(`${FIXTURES}/stepJoin/${f}`, `${dir}/${f}`);
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("STEP ")) seen.push(line);
	}
	const want = [
		"STEP start 2",
		"STEP rolled back fatal then 2 frame=0",
		"STEP join rejected fatal",
		"STEP rolled back fatal then 2 frame=0",
		"STEP all rejected fatal",
		"STEP reloaded 3",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "a task that crashed under step() and that the program awaits again did not reject with the crash");
	}
	console.log(`ok   ${tag}`);
}

function stepSpareCrash(): void {
	const tag = "hcrStepSpareCrash";
	const dir = freshDir(`${TMP}/stepSpareCrash`);
	for (const f of ["hold.h", "logic.ms", "fixed.txt"]) copy(`${FIXTURES}/step/${f}`, `${dir}/${f}`);
	for (const f of readDir(`${FIXTURES}/stepSpare`)) copy(`${FIXTURES}/stepSpare/${f}`, `${dir}/${f}`);
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("STEP ")) seen.push(line);
	}
	const want = ["STEP start 2 extra=0", "STEP rolled back then 2 queued ran 2 extra=0", "STEP reloaded 3"];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "a crash under step() inside a wait that started a spare left the spare wanted");
	}
	console.log(`ok   ${tag}`);
}

function crossImageNew(): void {
	const tag = "hcrCrossImageNew";
	const dir = freshDir(`${TMP}/crossNew`);
	for (const f of readDir(`${FIXTURES}/crossNew`)) copy(`${FIXTURES}/crossNew/${f}`, `${dir}/${f}`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr"], "an image that constructs another image's classes did not build");
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	if (!succeeded(ran) || !both(ran).contains("NEW kept 3 child")) {
		console.log(both(ran));
		failWith(tag, "msc run --hcr could not construct classes declared in another image");
	}
	console.log(`ok   ${tag}`);
}

function genericCtor(): void {
	const tag = "hcrGenericCtor";
	const dir = freshDir(`${TMP}/genericCtor`);
	for (const f of readDir(`${FIXTURES}/genericCtor`)) copy(`${FIXTURES}/genericCtor/${f}`, `${dir}/${f}`);
	const plain = msc(dir, ["run", "--target=js", "app.ms"]);
	need(tag, succeeded(plain) && both(plain).contains("GENERIC plain 41:1 42:1 kept:1 stamp=3"), "generic constructor type variants failed on JavaScript");
	mustBuild(tag, dir, ["build", "app.ms", "--hcr"], "generic constructor calls across images did not build");
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("GENERIC ")) seen.push(line);
	}
	const want = [
		"GENERIC before 41:1 42:1 kept:1 stamp=3",
		"GENERIC after 41:2 42:2 kept:2 stamp=4",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "generic constructors did not run their newest bodies across image owners");
	}
	console.log(`ok   ${tag}`);
}

function genericOps(): void {
	const tag = "hcrGenericOps";
	const dir = freshDir(`${TMP}/genericOps`);
	for (const f of readDir(`${FIXTURES}/genericOps`)) copy(`${FIXTURES}/genericOps/${f}`, `${dir}/${f}`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr"], "foreign generic lifecycle references did not build");
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	let drops: int32 = 0;
	let values = false;
	for (const line of lines(both(ran))) {
		if (line == "DROP") drops += 1;
		if (line == "OPS 9 10 kept") values = true;
	}
	if (!succeeded(ran) || !values || drops != 3) {
		console.log(both(ran));
		failWith(tag, "captured generic state must survive calls and destroy its three cells exactly once");
	}
	console.log(`ok   ${tag}`);
}

function genericIdentity(): void {
	const tag = "hcrGenericIdentity";
	const dir = freshDir(`${TMP}/genericIdentity`);
	for (const f of readDir(`${FIXTURES}/genericIdentity`)) copy(`${FIXTURES}/genericIdentity/${f}`, `${dir}/${f}`);
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("IDENT ")) seen.push(line);
	}
	const want = [
		"IDENT 2 3 4x t v1 given 7 peek 1.5",
		"IDENT 2 3 4x t v1 given 7 peek 1.5",
		"IDENT 2 3 4x t v2 given 7 peek 1.5",
		"IDENT 2 3 4x t v3 given 7 peek 1.5",
		"IDENT layout restart required names Box generic: true",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "a generic class instance must keep one TypeInfo across images and reloads, and a layout edit must still require a restart");
	}
	console.log(`ok   ${tag}`);
}

function exitDestroy(): void {
	const tag = "hcrExitDestroy";
	const dir = freshDir(`${TMP}/exitDestroy`);
	for (const f of readDir(`${FIXTURES}/exitDestroy`)) copy(`${FIXTURES}/exitDestroy/${f}`, `${dir}/${f}`);
	const want = ["EXIT run app logic", "EXIT destroy app", "EXIT destroy logic"];
	mustBuild(tag, dir, ["build", "app.ms", "--hcr"], "the --hcr build failed");
	for (const args of [["run", "app.ms"], ["run", "--hcr", "app.ms"]]) {
		const ran = msc(dir, args);
		const seen: string[] = [];
		for (const line of lines(both(ran))) {
			if (line.startsWith("EXIT ")) seen.push(line);
		}
		if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
			console.log(both(ran));
			failWith(tag, `msc ${args.join(" ")}: module globals were not destroyed once each at exit, entry first`);
		}
	}
	console.log(`ok   ${tag}`);
}

function retainReport(): void {
	const tag = "hcrRetainReport";
	const dir = freshDir(`${TMP}/retainReport`);
	for (const f of readDir(`${FIXTURES}/retain`)) copy(`${FIXTURES}/retain/${f}`, `${dir}/${f}`);
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("RETAIN ")) seen.push(line);
	}
	const want = [
		"RETAIN start 2",
		"RETAIN gen 1 bytes 3",
		"RETAIN gen 2 bytes 4",
		"RETAIN gen 3 bytes 5",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "lastReload() did not report growing generations and retained copy bytes");
	}
	console.log(`ok   ${tag}`);
}

function reloadOff(): void {
	const tag = "hcrReloadOff";
	const dir = freshDir(`${TMP}/reloadOff`);
	copy(`${FIXTURES}/reloadOff/main.ms`, `${dir}/main.ms`);
	for (const args of [["run", "main.ms"], ["run", "--target=js", "main.ms"]]) {
		const ran = msc(dir, args);
		if (!succeeded(ran) || !both(ran).contains("reload without --hcr: no change")) {
			console.log(both(ran));
			failWith(tag, `msc ${args.join(" ")}: reload() without --hcr should answer no change`);
		}
	}
	console.log(`ok   ${tag}`);
}

function runPrebuilt(tag: string, dir: string, modules: string[], prefix: string, want: string[]): void {
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	copy(STD_HOST, `${dir}/host.cms`);
	mustBuild(tag, dir, ["build", "host.cms", `--output=${exe}`], "thin host build failed");
	if (SAN) sanRuntime(dir);
	ensureDir(`${dir}/run`);
	for (const name of [`module${ext}`, `module.core${ext}`, `module${ext}.hcrabi`]) {
		copy(`${dir}/g1/${name}`, `${dir}/run/${name}`);
	}
	for (const moduleId of modules) {
		const name = `module.${moduleId}${ext}`;
		copy(`${dir}/g1/${name}`, `${dir}/run/${name}`);
	}
	const ran = execFileResult(`${dir}/${exe}`, ["run", "module"], dir);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith(prefix + " ")) seen.push(line);
	}
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "the prebuilt generations did not produce the expected consumer transitions");
	}
	console.log(`ok   ${tag}`);
}

function buildLogicGenerations(tag: string, fixture: string, edits: string[]): string {
	const dir = freshDir(`${TMP}/${fixture}`);
	copy(`${FIXTURES}/${fixture}/app.ms`, `${dir}/app.ms`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	for (let i = 0; i < edits.length; i += 1) {
		copy(`${FIXTURES}/${fixture}/${edits[i]}`, `${dir}/logic.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${i + 1}/module${sharedLibraryExt()}`],
			`generation ${i + 1} failed to build`);
	}
	return dir;
}

function sharedVariable(): void {
	const tag = "hcrSharedVariable";
	const dir = buildLogicGenerations(tag, "sharedVariable",
		["logic.ms", "logicEdit.ms", "logicCounterType.ms", "logicTitleType.ms", "logicEditAgain.ms"]);
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-SHARED", [
		"HCR-SHARED start: 5 one 12 12",
		"HCR-SHARED g2: reloaded logic",
		"HCR-SHARED edited constants: 9 two 23 23",
		"HCR-SHARED g3: rejected",
		"HCR-SHARED binding counter: app true symbol true",
		"HCR-SHARED after counter type rejection: 9 two 34 34",
		"HCR-SHARED g4: rejected",
		"HCR-SHARED binding TITLE: app true symbol true",
		"HCR-SHARED after title type rejection: 9 two 45 45",
		"HCR-SHARED g5: reloaded logic",
		"HCR-SHARED edited constants again: 11 three 56 56",
	]);
}

function namespaceVariable(): void {
	const tag = "hcrNamespaceVariable";
	const dir = buildLogicGenerations(tag, "namespaceVariable", ["logic.ms", "logicEdit.ms"]);
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-NS", [
		"HCR-NS start: 3 3 2 x",
		"HCR-NS g2: reloaded logic",
		"HCR-NS edited: 4 10 12 x",
	]);
}

function namespaceShift(): void {
	const tag = "hcrNamespaceShift";
	const fixture = `${FIXTURES}/namespaceShift`;
	const dir = freshDir(`${TMP}/namespaceShift`);
	copy(`${fixture}/app.ms`, `${dir}/app.ms`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	const generations = [["reader.ms", "state.ms"], ["readerEdit.ms", "state.ms"], ["readerEdit.ms", "stateEdit.ms"]];
	for (let i = 0; i < generations.length; i += 1) {
		copy(`${fixture}/${generations[i][0]}`, `${dir}/reader.ms`);
		copy(`${fixture}/${generations[i][1]}`, `${dir}/state.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${i + 1}/module${sharedLibraryExt()}`],
			`generation ${i + 1} failed to build`);
	}
	runPrebuilt(tag, dir, ["state", "reader", "support"], "HCR-SHIFT", [
		"HCR-SHIFT start: 2 2",
		"HCR-SHIFT g2: reloaded reader",
		"HCR-SHIFT reader: 3 3 n3",
		"HCR-SHIFT g3: reloaded state",
		"HCR-SHIFT state: 4 4 n4",
	]);
}

function layoutHolder(variant: string, grown: boolean): string[] {
	const more = grown ? "b: string; " : "";
	const moreValue = grown ? "b: \"beta\", " : "";
	return match (variant) {
		"array" => ["let held: P[] = [];", "held.push(make());", "held = [];"],
		"closure" => ["let held: (() => int32) | null = null;", "const p = make(); held = (): int32 => p.a;", "held = null;"],
		"list" => ["class List<T> { items: T[] = []; }\nlet held: List<P> = new List<P>();", "held.items.push(make());", "held = new List<P>();"],
		"map" => ["let held = new HashMap<string, P>();", "held.set(\"k\", make());", "held = new HashMap<string, P>();"],
		"alias" => ["export interface Q { a: int32; " + more + "c: int32; }\nlet held: P | null = null;", "const q: Q = { a: 7, " + moreValue + "c: 1 }; held = q;", "held = null;"],
		"subclass" => ["export class Q extends P { z: int32 = 1; }\nlet held: P | null = null;", "held = new Q();", "held = null;"],
		_ => ["let held: P | null = null;", "held = make();", "held = null;"],
	};
}

function layoutLogic(variant: string, generation: int32): string {
	const grown = generation > 1;
	const isClass = variant == "class" || variant == "subclass";
	let declaration = grown ? "export interface P { a: int32; b: string; }" : "export interface P { a: int32; }";
	let literal = grown ? "{ a: 7, b: \"beta\" }" : "{ a: 7 }";
	if (isClass) {
		declaration = grown ? "export class P { a: int32 = 7; b: string = \"beta\"; }" : "export class P { a: int32 = 7; }";
		literal = "new P()";
	}
	const holder = layoutHolder(variant, grown);
	const handlerCounts = variant == "resume" ? " ${befores}/${afters}" : "";
	const lines = [
		declaration,
		holder[0],
		`function make(): P { return ${literal}; }`,
		`export function hold(): void { ${holder[1]} }`,
		`export function release(): void { ${holder[2]} }`,
		"export function fresh(): string { const p = make(); return " + (grown ? "`${p.a} ${p.b}" : "`${p.a}") + handlerCounts + "`; }",
	];
	if (variant == "handler") lines.push("@beforeReload\nfunction drop(): void { held = null; }");
	if (variant == "resume") {
		lines.push("let befores: int32 = 0;\nlet afters: int32 = 0;");
		lines.push("@beforeReload\nfunction pause(): void { befores += 1; }");
		lines.push("@afterReload\nfunction resume(): void { afters += 1; }");
	}
	if (generation > 2) lines.push("export const SALT: int32 = 3;");
	return lines.join("\n") + "\n";
}

function layoutStructLogic(generation: int32): string {
	const grown = generation > 1;
	return [
		grown ? "export struct S { a: int32; b: string; }" : "export struct S { a: int32; }",
		"export class Box { s: S; constructor() { this.s = " + (grown ? "{ a: 7, b: \"beta\" }" : "{ a: 7 }") + "; } }",
		"let held: Box | null = null;",
		"export function hold(): void { held = new Box(); }",
		"export function release(): void { held = null; }",
		"export function fresh(): string { const b = new Box(); return " + (grown ? "`${b.s.a} ${b.s.b}`" : "`${b.s.a}`") + "; }",
		generation > 2 ? "export const SALT: int32 = 3;" : "",
	].join("\n") + "\n";
}

function layoutVariant(variant: string, want: string[]): void {
	const tag = `hcrLayout_${variant}`;
	const dir = freshDir(`${TMP}/layout_${variant}`);
	copy(`${FIXTURES}/layoutReload/app.ms`, `${dir}/app.ms`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	for (let g: int32 = 1; g <= 3; g += 1) {
		put(`${dir}/logic.ms`, variant == "struct" ? layoutStructLogic(g) : layoutLogic(variant, g));
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${g}/module${sharedLibraryExt()}`], `generation ${g} failed to build`);
	}
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-LAYOUT", want);
}

const OWN_LIVE = "type 'P' in module 'logic' has 1 live values";

function layoutHeld(reason: string): string[] {
	return [
		"HCR-LAYOUT before: 7",
		`HCR-LAYOUT held: restart required logic | ${reason}`,
		"HCR-LAYOUT after held: 7",
		"HCR-LAYOUT released: reloaded logic | ",
		"HCR-LAYOUT after released: 7 beta",
	];
}

function layoutReload(): void {
	layoutVariant("module", layoutHeld(OWN_LIVE));
	layoutVariant("handler", [
		"HCR-LAYOUT before: 7",
		"HCR-LAYOUT held: reloaded logic | ",
		"HCR-LAYOUT after held: 7 beta",
		"HCR-LAYOUT released: reloaded logic | ",
		"HCR-LAYOUT after released: 7 beta",
	]);
	layoutVariant("resume", [
		"HCR-LAYOUT before: 7 0/0",
		`HCR-LAYOUT held: restart required logic | ${OWN_LIVE}`,
		"HCR-LAYOUT after held: 7 1/1",
		"HCR-LAYOUT released: reloaded logic | ",
		"HCR-LAYOUT after released: 7 beta 2/2",
	]);
}

function layoutVariants(): void {
	for (const variant of ["class", "array", "closure", "list", "map"]) layoutVariant(variant, layoutHeld(OWN_LIVE));
	layoutVariant("subclass", layoutHeld(`${OWN_LIVE}; type 'Q' in module 'logic' has 1 live values`));
	layoutVariant("alias", layoutHeld(`${OWN_LIVE}; type 'Q' in module 'logic' has 1 live values`));
	layoutVariant("struct", [
		"HCR-LAYOUT before: 7",
		"HCR-LAYOUT held: restart required logic | type 'S' in module 'logic' is held by value",
		"HCR-LAYOUT after held: 7",
		"HCR-LAYOUT released: restart required logic | type 'S' in module 'logic' is held by value",
		"HCR-LAYOUT after released: 7",
	]);
}

function modulePassReload(): void {
	const tag = "hcrModulePassReload";
	const fixture = "modulePass";
	const dir = freshDir(`${TMP}/${fixture}`);
	for (const name of ["build.ms", "refresh.ms", "app.ms"]) copy(`${FIXTURES}/${fixture}/${name}`, `${dir}/${name}`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	const edits = ["logic.ms", "logicEdit.ms"];
	for (let i = 0; i < edits.length; i += 1) {
		copy(`${FIXTURES}/${fixture}/${edits[i]}`, `${dir}/logic.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${i + 1}/module${sharedLibraryExt()}`],
			`generation ${i + 1} failed to build`);
	}
	runPrebuilt(tag, dir, ["logic", "support", "refresh"], "HCR-PASS", [
		"HCR-PASS start: tpl-g1 tpl-g1 | register logic.ms:Counter,template tpl-g1",
		"HCR-PASS g2: reloaded logic | reregister logic.ms:Counter",
		"HCR-PASS after reload: tpl-g2! tpl-g2! | template tpl-g2",
	]);
}

function registryVariables(): void {
	const tag = "hcrRegistryVariables";
	const dir = buildLogicGenerations(tag, "registryVariables", [
		"logic.ms", "logicAdd.ms", "logicRemove.ms", "logicReintroduce.ms",
		"logicReset.ms", "logicThrowInt.ms", "logicThrowString.ms", "logicRecovery.ms",
	]);
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-VARS", [
		"HCR-VARS exception control: true",
		"HCR-VARS start: v1 6 seed! 11",
		"HCR-VARS g2: reloaded logic",
		"HCR-VARS added: v2 6 seed! 11 20 new",
		"HCR-VARS mutated: v2 7 seed!! 12 21 new!",
		"HCR-VARS g3: reloaded logic",
		"HCR-VARS removed: v3 7 seed!!",
		"HCR-VARS g4: reloaded logic",
		"HCR-VARS reintroduced: v4 8 seed!!! 70 80 fresh",
		"HCR-VARS g5: reloaded logic",
		"HCR-VARS reset report: count true memo true",
		"HCR-VARS reset: v5 200 300 70 80 fresh",
		"HCR-VARS g6: rejected logic",
		"HCR-VARS after integer initializer throws: v5 208 312 70 80 fresh",
		"HCR-VARS g7: rejected logic",
		"HCR-VARS after string initializer throws: v5 217 325 70 80 fresh",
		"HCR-VARS g8: reloaded logic",
		"HCR-VARS after recovery: v8 217 325 70 80 fresh 900 ready",
	]);
}

// ---- hcrModuleTdz: a module binding's initialized flag follows its cell across reloads ----

function moduleTdz(): void {
	const tag = "hcrModuleTdz";
	const dir = buildLogicGenerations(tag, "moduleTdz", ["logic.ms", "logicAdd.ms", "logicReset.ms"]);
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-TDZ", [
		"HCR-TDZ early: Cannot access 'later' before initialization",
		"HCR-TDZ start: v1 6 8",
		"HCR-TDZ g2: reloaded logic",
		"HCR-TDZ added: v2 6 8 20 tag",
		"HCR-TDZ g3: reloaded logic",
		"HCR-TDZ reset: v3 200 9 21 tag",
	]);
}

function registryGeneric(): void {
	const tag = "hcrRegistryGeneric";
	const dir = freshDir(`${TMP}/registryGeneric`);
	for (const f of ["app.ms", "build.ms"]) copy(`${FIXTURES}/registryGeneric/${f}`, `${dir}/${f}`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	const generations = [
		["a.ms", "b.ms", "cell.ms"],
		["aEdit.ms", "b.ms", "cell.ms"],
		["aEdit.ms", "bEdit.ms", "cell.ms"],
		["aEdit.ms", "bEdit.ms", "cellBody.ms"],
	];
	for (let i = 0; i < generations.length; i += 1) {
		const generation = generations[i];
		copy(`${FIXTURES}/registryGeneric/${generation[0]}`, `${dir}/a.ms`);
		copy(`${FIXTURES}/registryGeneric/${generation[1]}`, `${dir}/b.ms`);
		copy(`${FIXTURES}/registryGeneric/${generation[2]}`, `${dir}/cell.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${i + 1}/module${sharedLibraryExt()}`],
			`generation ${i + 1} failed to build`);
	}
	runPrebuilt(tag, dir, ["a", "b", "cell", "support"], "HCR-GENERIC", [
		"HCR-GENERIC start: 5 7 hits 2",
		"HCR-GENERIC g2: reloaded a,b",
		"HCR-GENERIC new instances: new9 7 hits 5",
		"HCR-GENERIC g3: reloaded b",
		"HCR-GENERIC second consumer: new9 b8 hits 9",
		"HCR-GENERIC g4: reloaded cell",
		"HCR-GENERIC private helper edit: new9 b8 hits 49",
	]);
}

function functionValues(): void {
	const tag = "hcrFunctionValues";
	const dir = buildLogicGenerations(tag, "functionValues", ["logic.ms", "logicEdit.ms", "logicReset.ms"]);
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-FN", [
		"HCR-FN g1: direct 1 held 1 table 1 rebound 1 local 1001 adder 102",
		"HCR-FN g2: reloaded logic []",
		"HCR-FN after g2: direct 2 held 2 fresh 2 table 2 rebound 2 local 2002 fresh-local 2002 adder 103 fresh-adder 203",
		"HCR-FN state before reset: held-tick 10 direct-tick 20 snapshot 20",
		"HCR-FN g3: reloaded logic [reset variables: logic.count]",
		"HCR-FN after g3 reset: held-tick 0 direct-tick 0 held-tick 0 snapshot 300 held-version 3 rebound 3",
	]);
}

function dollarNames(): void {
	const tag = "hcrDollarNames";
	const dir = buildLogicGenerations(tag, "dollarNames", ["logic.ms", "logicEdit.ms", "logicDollarLayout.ms", "logicLayout.ms"]);
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-DOLLAR", [
		"HCR-DOLLAR g1: $step 1 step 1 boxes 1 1",
		"HCR-DOLLAR g2: reloaded logic []",
		"HCR-DOLLAR after g2: $step 2 step 2 direct 2 2",
		"HCR-DOLLAR g3: restart required logic [type '$Box' in module 'logic' has 2 live values]",
		"HCR-DOLLAR g4: restart required logic [type 'Box' in module 'logic' has 2 live values]",
	]);
}

function inlineFunctions(): void {
	const tag = "hcrInlineFunctions";
	const dir = buildLogicGenerations(tag, "inlineFunctions", ["logic.ms", "logicEdit.ms"]);
	runPrebuilt(tag, dir, ["logic", "support"], "HCR-INLINE", [
		"HCR-INLINE g1: step 7 quotient -3",
		"HCR-INLINE g2: reloaded logic",
		"HCR-INLINE after g2: step 302 quotient -4",
	]);
}

function fileDependency(): void {
	const tag = "hcrFileDependency";
	const dir = freshDir(`${TMP}/fileDependency`);
	for (const sub of ["app", "greeter"]) ensureDir(`${dir}/${sub}`);
	for (const f of ["app/app.ms", "app/build.ms", "greeter/build.ms", "greeter/index.ms", "greeterEdit.ms"]) {
		copy(`${FIXTURES}/fileDependency/${f}`, `${dir}/${f}`);
	}
	const ran = msc(`${dir}/app`, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-DEP ")) seen.push(line);
	}
	const want = ["HCR-DEP start hello v1", "HCR-DEP reloaded greeter/index hello v2"];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "an edit of a file: dependency did not reload into the running app");
	}
	console.log(`ok   ${tag}`);
}

function coreCell(): void {
	const tag = "hcrCoreCell";
	const dir = freshDir(`${TMP}/coreCell`);
	for (const sub of ["app", "box"]) ensureDir(`${dir}/${sub}`);
	for (const f of ["app/app.ms", "app/logic.ms", "box/box.ms", "logicEdit.ms"]) {
		copy(`${FIXTURES}/coreCell/${f}`, `${dir}/${f}`);
	}
	const ran = msc(`${dir}/app`, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-CELL ")) seen.push(line);
	}
	const want = ["HCR-CELL start 1 0 0", "HCR-CELL reloaded logic 3"];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "array cells boxed by a project image first and by a core module later did not link and reload");
	}
	console.log(`ok   ${tag}`);
}

function coreOp(): void {
	const tag = "hcrCoreOp";
	const dir = freshDir(`${TMP}/coreOp`);
	for (const sub of ["app", "lib"]) ensureDir(`${dir}/${sub}`);
	for (const f of ["app/app.ms", "app/logic.ms", "lib/lib.ms", "logicEdit.ms"]) {
		copy(`${FIXTURES}/coreOp/${f}`, `${dir}/${f}`);
	}
	const ran = msc(`${dir}/app`, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-OP ")) seen.push(line);
	}
	const want = [
		"HCR-OP start row s+ 2 column wide 7",
		"HCR-OP cleared none none 0",
		"HCR-OP reloaded logic column s++ 12",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "lifted operations a project image needs first and a core module needs later did not link and reload");
	}
	console.log(`ok   ${tag}`);
}

function coreGenericInit(): void {
	const tag = "hcrCoreGenericInit";
	const dir = freshDir(`${TMP}/coreGenericInit`);
	for (const sub of ["app", "lib"]) ensureDir(`${dir}/${sub}`);
	for (const f of ["app/app.ms", "app/logic.ms", "lib/lib.ms", "logicEdit.ms"]) {
		copy(`${FIXTURES}/coreGenericInit/${f}`, `${dir}/${f}`);
	}
	const ran = msc(`${dir}/app`, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-GI ")) seen.push(line);
	}
	const want = [
		"HCR-GI start V6 42 applib app=4 lib=3",
		"HCR-GI reloaded logic",
		"HCR-GI after V6 357 applib app=4 lib=3",
	];
	if (!succeeded(ran) || seen.join("
") != want.join("
")) {
		console.log(both(ran));
		failWith(tag, "a generic class instance a project image and a core module both construct did not link and reload");
	}
	console.log(`ok   ${tag}`);
}

function overloadCall(): void {
	const tag = "hcrOverloadCall";
	const dir = freshDir(`${TMP}/overloadCall`);
	for (const f of ["app.ms", "caller.ms", "shapes.ms", "shapesEdit.ms"]) copy(`${FIXTURES}/overloadCall/${f}`, `${dir}/${f}`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=img/module${sharedLibraryExt()}`], "calls into another image's overloads did not link");
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-OV ")) seen.push(line);
	}
	const want = [
		"HCR-OV start s x n 2 ns 2 n 3 n 7",
		"HCR-OV reloaded shapes",
		"HCR-OV after s x n2 4 ns 2 n2 6 n2 14",
	];
	if (!succeeded(ran) || seen.join("|") != want.join("|")) {
		console.log(both(ran));
		failWith(tag, "a call into another image's second or later overload did not bind through the registry and follow a reload");
	}
	console.log(`ok   ${tag}`);
}

function coreConstant(): void {
	const tag = "hcrCoreConstant";
	const dir = freshDir(`${TMP}/coreConstant`);
	for (const f of ["app.ms", "geo.ms", "scale.ms", "scaleEdit.ms"]) copy(`${FIXTURES}/coreConstant/${f}`, `${dir}/${f}`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=img/module${sharedLibraryExt()}`], "an image reading a core static constant did not link");
	const ran = msc(dir, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-CC ")) seen.push(line);
	}
	const want = [
		"HCR-CC start 6.283185307179586 true",
		"HCR-CC reloaded scale",
		"HCR-CC after 9.42477796076938 true",
	];
	if (!succeeded(ran) || seen.join("|") != want.join("|")) {
		console.log(both(ran));
		failWith(tag, "a core static constant was not folded in an image, or a project constant edit did not reach the image after a reload");
	}
	console.log(`ok   ${tag}`);
}

function macroHelper(): void {
	const tag = "hcrMacroHelper";
	for (const variant of ["base", "second"]) {
		const dir = freshDir(`${TMP}/macroHelper${variant}`);
		const files = variant == "base" ? ["app.ms", "tools.ms"] : ["app.ms", "tools.ms", "helpers.ms"];
		for (const f of files) copy(`${FIXTURES}/macroHelper/${variant}/${f}`, `${dir}/${f}`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=img/module${sharedLibraryExt()}`], `an exported helper only a macro calls (${variant}) did not build`);
		const ran = msc(dir, ["run", "--hcr", "app.ms"]);
		const seen: string[] = [];
		for (const line of lines(both(ran))) {
			if (line.startsWith("HCR-MH ")) seen.push(line);
		}
		if (!succeeded(ran) || seen.length != 1 || seen[0] != "HCR-MH B2 0") {
			console.log(both(ran));
			failWith(tag, `an exported helper only a macro calls (${variant}) reached the core image or left the project module without an image`);
		}
	}
	const dir = freshDir(`${TMP}/macroHelperRuntime`);
	for (const f of ["runtimeCall.ms", "tools.ms"]) copy(`${FIXTURES}/macroHelper/base/${f}`, `${dir}/${f}`);
	const refused = msc(dir, ["build", "runtimeCall.ms", "--hcr", `--output=img/module${sharedLibraryExt()}`]);
	if (succeeded(refused) || both(refused).indexOf("'arity' calls 'childCount'", 0) < 0) {
		console.log(both(refused));
		failWith(tag, "a run-time call to a helper only the macro VM can run was not refused by name");
	}
	console.log(`ok   ${tag}`);
}

function rewriteCoreNativeHeader(dir: string, include: string): void {
	const revision = `${performance.now()}`.replaceAll(".", "");
	put(`${dir}/box/shared.h`, `${include}#define HCR_NATIVE_REV ${revision}\n`);
	settleSecond();
}

function coreNative(): void {
	const tag = "hcrCoreNative";
	const dir = freshDir(`${TMP}/coreNative`);
	for (const sub of ["app", "box"]) ensureDir(`${dir}/${sub}`);
	for (const f of ["app/app.ms", "app/logic.ms", "box/box.ms", "box/native.h", "box/first.c", "box/second.c", "box/extra.h"]) {
		copy(`${FIXTURES}/coreNative/${f}`, `${dir}/${f}`);
	}
	const app = `${dir}/app`;
	const build = ["build", "app.ms", "--hcr", `--output=img/module${sharedLibraryExt()}`];
	rewriteCoreNativeHeader(dir, "");
	mustBuild(tag, app, build, "the first build failed");

	rewriteCoreNativeHeader(dir, "");
	const ran = msc(app, ["run", "--hcr", "app.ms"]);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-NATIVE ")) seen.push(line);
	}
	const want = [
		"HCR-NATIVE start 3 v1",
		"HCR-NATIVE reloaded logic v2",
		"HCR-NATIVE restart required the core image changed (runtime, standard library or toolchain)",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "a session that began by recompiling one core native beside a cached one did not reload a module edit, or did not ask for a restart once that native's header was edited");
	}

	const edits = [
		{ include: "", label: "v4", what: "its header changed" },
		{ include: "#include \"extra.h\"\n", label: "v5", what: "its header gained an include" },
	];
	for (const edit of edits) {
		rewriteCoreNativeHeader(dir, edit.include);
		mustBuild(tag, app, build, `the build after ${edit.what} failed`);
		const recompiled = linkInputKeys(app);
		put(`${app}/logic.ms`, `export function label(): string {\n\treturn "${edit.label}";\n}\n`);
		mustBuild(tag, app, build, "the body-edit build failed");
		let relinked = 0;
		for (const key of linkInputKeys(app)) {
			if (!recompiled.includes(key)) relinked += 1;
		}
		need(tag, relinked == 1, `the build after a body edit relinked ${relinked} images, expected only logic's, once one core native was recompiled because ${edit.what}`);
	}
	console.log(`ok   ${tag}`);
}

function globalCell(): void {
	const tag = "hcrGlobalCell";
	const dir = freshDir(`${TMP}/globalCell`);
	for (const f of ["app.ms", "build.ms", "refresh.ms", "tally.ms"]) copy(`${FIXTURES}/globalCell/${f}`, `${dir}/${f}`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	const edits = ["logic.ms", "logicEdit.ms"];
	for (let i = 0; i < edits.length; i += 1) {
		copy(`${FIXTURES}/globalCell/${edits[i]}`, `${dir}/logic.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${i + 1}/module${sharedLibraryExt()}`],
			`generation ${i + 1} of global imports holding module-level arrays failed to build`);
	}
	runPrebuilt(tag, dir, ["logic", "support", "refresh", "tally"], "HCR-GLOBAL", [
		"HCR-GLOBAL start: g1 1",
		"HCR-GLOBAL g2: reloaded logic",
		"HCR-GLOBAL after: g1,g2 2",
	]);
}

function borrowAcrossReload(): void {
	const tag = "hcrBorrowAcrossReload";
	const dir = freshDir(`${TMP}/borrowAcrossReload`);
	for (const f of ["app.ms", "state.ms"]) copy(`${FIXTURES}/borrowAcrossReload/${f}`, `${dir}/${f}`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	const edits = ["logic.ms", "logicEdit.ms"];
	for (let i = 0; i < edits.length; i += 1) {
		copy(`${FIXTURES}/borrowAcrossReload/${edits[i]}`, `${dir}/logic.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${i + 1}/module${sharedLibraryExt()}`],
			`generation ${i + 1} failed to build`);
	}
	runPrebuilt(tag, dir, ["logic", "state", "support"], "HCR-BORROW", [
		"HCR-BORROW start: [label-1] [field-1]",
		"HCR-BORROW g2: logic",
		"HCR-BORROW after: [label-1]4 [field-2]4",
	]);
}

function watchWarmDependency(): void {
	const tag = "hcrWatchWarmDependency";
	const root = freshDir(`${TMP}/watchWarmDependency`);
	for (const sub of ["app", "greeter"]) ensureDir(`${root}/${sub}`);
	for (const f of ["app/app.ms", "app/build.ms", "greeter/build.ms", "greeter/index.ms", "greeterEdit.ms"]) {
		copy(`${FIXTURES}/fileDependency/${f}`, `${root}/${f}`);
	}
	const steps: WatchStep[] = [
		{ file: "../greeterEdit.ms", target: "../greeter/index.ms", warm: true, fails: false },
	];
	replayMatchesCold(tag, `${root}/app`, `${FIXTURES}/fileDependency/app`, ["../greeter/index.ms"], steps);
	console.log(`ok   ${tag}`);
}

function watchLink(): void {
	const tag = "hcrWatchLink";
	const dir = freshDir(`${TMP}/watchLink`);
	for (const f of ["app.ms", "logic.ms", "logicBodyEdit.ms"]) copy(`${FIXTURES}/${f}`, `${dir}/${f}`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr"], "cold build failed");
	const temp = freshDir(`${TMP}/watchLinkTemp`);
	ensureDir(`${temp}/msc-plan`);
	let planted = false;
	for (const f of readDir(`${dir}/out/debug/.cache`)) {
		if (planted || !f.endsWith(".o")) continue;
		copy(`${dir}/out/debug/.cache/${f}`, `${temp}/msc-plan/msc-plan-input.o`);
		planted = true;
	}
	need(tag, planted, "the cold build left no object to plant at the plan input");
	put(`${dir}/replay.txt`, "logicBodyEdit.ms logic.ms\n");
	const prevTemp = env.get("TEMP");
	const prevTmpdir = env.get("TMPDIR");
	env.set("TEMP", temp);
	env.set("TMPDIR", temp);
	const watched = msc(dir, ["build", "app.ms", "--hcr", "--watch-replay=replay.txt"]);
	env.set("TEMP", prevTemp);
	env.set("TMPDIR", prevTmpdir);
	const statuses: string[] = [];
	for (const line of lines(both(watched))) {
		if (line.startsWith("watch: build ")) statuses.push(line);
	}
	if (statuses.length != 2 || statuses[1].contains(" failed ")) {
		console.log(both(watched));
		failWith(tag, "a linked watch build failed after its session captured link plans over a real placeholder object");
	}
	console.log(`ok   ${tag}`);
}

function typeInfoLocality(): void {
	const tag = "hcrTypeInfoLocality";
	const dir = freshDir(`${TMP}/typeInfoLocality`);
	for (const f of readDir(`${FIXTURES}/typeInfoLocality`)) copy(`${FIXTURES}/typeInfoLocality/${f}`, `${dir}/${f}`);
	const steps: WatchStep[] = [
		{ file: "logicCell.ms", target: "logic.ms", warm: true, fails: false },
		{ file: "logicClass.ms", target: "logic.ms", warm: false, fails: false },
	];
	replayMatchesCold(tag, dir, `${FIXTURES}/typeInfoLocality`, ["logic.ms"], steps);
	const debug = `${dir}/out/debug`;
	let app = "";
	let logic = "";
	for (const f of cFilesIn(`${debug}/watch0`)) {
		if (f.startsWith("_")) continue;
		if (f.endsWith("appOms.c")) app = f;
		if (f.endsWith("logicOms.c")) logic = f;
	}
	need(tag, app != "" && logic != "", "the watch replay emitted no C for app.ms or logic.ms");
	const appFirst = read(`${debug}/watch0/${app}`);
	for (let n = 1; n <= steps.length; n += 1) {
		const label = `step ${n} (${steps[n - 1].file})`;
		need(tag, read(`${debug}/watch${n}/${logic}`).contains("msHcrTypeInfo("), `${label}: logic.ms registers no TypeInfo`);
		need(tag, read(`${debug}/watch${n}/${app}`) == appFirst, `${label} changed app.ms's C although only logic.ms changed`);
	}
	console.log(`ok   ${tag}`);
}

function imageNameCollision(): void {
	const tag = "hcrImageNameCollision";
	const dir = freshDir(`${TMP}/imageCollision`);
	ensureDir(`${dir}/a`);
	for (const f of ["app.ms", "a/b.ms", "a.b.ms"]) copy(`${FIXTURES}/imageCollision/${f}`, `${dir}/${f}`);
	const r = msc(dir, ["build", "--hcr", `--output=out/collide/app${sharedLibraryExt()}`, "app.ms"]);
	need(tag, !succeeded(r) && both(r).contains("both build the image 'a.b'"),
		"two modules that map to one image name built instead of failing");
	console.log(`ok   ${tag}`);
}

// ---- hcrWindowsReload: single-image LoadLibrary reload, four generations ----

function windowsReload(): void {
	const tag = "hcrWindowsReload";
	const probeDir = `${ROOT}/examples/hcrProbe`;
	const out = "out/windows";
	const gen = `${out}/gen`;
	freshDir(`${probeDir}/${out}`);
	for (const g of ["g1", "g2", "g3", "g4"]) ensureDir(`${probeDir}/${gen}/${g}`);
	const source = `${probeDir}/${out}/source`;
	ensureDir(source);
	const builds = [["module.ms", "g1"], ["moduleBodyEdit.ms", "g2"], ["moduleLayoutEdit.ms", "g3"]];
	for (const b of builds) {
		copy(`${probeDir}/${b[0]}`, `${source}/module.ms`);
		const log = mustBuild(tag, source, ["build", "module.ms", "--hcr", `--output=../gen/${b[1]}/module.dll`],
			`generation ${b[1]} failed to build`);
		put(`${probeDir}/${out}/${b[1]}.build.log`, log);
	}
	put(`${probeDir}/${gen}/g4/module.dll`, read(`${probeDir}/${gen}/g2/module.dll`).byteSlice(0, 512));
	const host = mustBuild(tag, ROOT, ["build", "examples/hcrProbe/hostWindows.ms", `--output=examples/hcrProbe/${out}/hcrHostWindows.exe`],
		"Windows probe host build failed");
	put(`${probeDir}/${out}/host.build.log`, host);

	const run = execFileResult(`${probeDir}/${out}/hcrHostWindows.exe`,
		[`${gen}/g1/module.dll`, `${gen}/g2/module.dll`, `${gen}/g3/module.dll`, `${gen}/g4/module.dll`], probeDir);
	const probeOut = lines(run.output);
	const states: string[] = [];
	const seen: string[] = [];
	for (const line of probeOut) {
		const at = line.indexOf(" state=");
		if (at >= 0 && (line.startsWith("HCR-PROBE loaded ") || line.startsWith("HCR-PROBE reloaded "))) {
			states.push(line.slice(at + 7, line.length));
		}
		if (line.startsWith("HCR-PROBE call ") || line.startsWith("HCR-PROBE rejected ")) seen.push(line);
	}
	need(tag, states.length == 3 && states[0] != "" && states[0] == states[1] && states[1] == states[2],
		"the count registry cell storage changed across the two accepted reloads");
	const want = [
		`HCR-PROBE call ${gen}/g1/module.dll -> 10`,
		`HCR-PROBE call ${gen}/g2/module.dll -> 40`,
		`HCR-PROBE call ${gen}/g3/module.dll -> 30`,
		`HCR-PROBE rejected ${gen}/g4/module.dll (load)`,
		`HCR-PROBE call ${gen}/g3/module.dll -> 40`,
	];
	if (!succeeded(run) || seen.join("\n") != want.join("\n")) {
		console.log(both(run));
		failWith(tag, "the Windows probe did not accept the added variable and retain the current functions after a corrupt image");
	}
	console.log("ok   hcrWindowsReload");
}

function fsWatch(): void {
	const tag = "hcrFsWatch";
	const dir = freshDir(`${TMP}/fsWatch`);
	copy(`${FIXTURES}/watch/watch.ms`, `${dir}/watch.ms`);
	const exe = platform == "windows" ? "watch.exe" : "watch";
	mustBuild(tag, dir, ["build", "watch.ms", `--output=${exe}`], "the watch fixture did not build");
	const ran = execFileResult(`${dir}/${exe}`, [], dir);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("WATCH ")) seen.push(line);
	}
	const want = platform == "windows" ? [
		"WATCH missing opened: false",
		"WATCH write before the first wait: true",
		"WATCH write in a subdirectory: true",
		"WATCH a renamed save is reported closed: true",
		"WATCH a missing file has no writer: true",
		"WATCH a closed file proves no writer: true",
		"WATCH a writer close is observable: true",
		"WATCH after close: ended true",
		"WATCH closed while waiting: ended true",
	] : platform == "linux" ? [
		"WATCH missing opened: false",
		"WATCH write before the first wait: true",
		"WATCH write in a subdirectory: true",
		"WATCH a renamed save is reported closed: true",
		"WATCH a closed write is reported closed: true",
		"WATCH a missing file has no writer: true",
		"WATCH a closed file proves no writer: false",
		"WATCH a writer close is observable: true",
		"WATCH after close: ended true",
		"WATCH closed while waiting: ended true",
	] : platform == "darwin" ? [
		"WATCH missing opened: false",
		"WATCH write before the first wait: true",
		"WATCH write in a subdirectory: true",
		"WATCH an in-place rewrite is seen: true",
		"WATCH a delete is seen: true",
		"WATCH a renamed save is reported closed: true",
		"WATCH a missing file has no writer: true",
		"WATCH a closed file proves no writer: false",
		"WATCH a writer close is observable: false",
		"WATCH after close: ended true",
		"WATCH closed while waiting: ended true",
	] : [
		"WATCH missing opened: false",
		"WATCH tree opened: false",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "std/fs/watch did not report the expected changes");
	}
	console.log("ok   hcrFsWatch");
}

// ---- hcrInstanceofReload: the class display survives a module reload ----

function instanceofReload(): void {
	const tag = "hcrInstanceofReload";
	const ext = sharedLibraryExt();
	const exe = platform == "windows" ? "host.exe" : "host";
	const dir = freshDir(`${TMP}/instanceof`);
	for (const f of ["app.ms", "logic.ms", "logicEdit.ms"]) copy(`${FIXTURES}/instanceof/${f}`, `${dir}/${f}`);
	copy(STD_HOST, `${dir}/host.cms`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g1/module${ext}`], "the first generation did not build");
	copy(`${FIXTURES}/instanceof/logicEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g2/module${ext}`], "the edited generation did not build");
	mustBuild(tag, dir, ["build", "host.cms", `--output=${exe}`], "thin host build failed");
	ensureDir(`${dir}/run`);
	for (const image of readDir(`${dir}/g1`)) {
		copy(`${dir}/g1/${image}`, `${dir}/run/${image}`);
	}
	const ran = execFileResult(`${dir}/${exe}`, ["run", "module"], dir);
	const seen: string[] = [];
	for (const line of lines(both(ran))) {
		if (line.startsWith("HCR-INST ")) seen.push(line);
	}
	if (!succeeded(ran) || seen.join("\n") != ["HCR-INST first 9", "HCR-INST reloaded 10"].join("\n")) {
		console.log(both(ran));
		failWith(tag, "reloading logic did not keep the class instance tests exact");
	}
	console.log(`ok   ${tag}`);
}

function dynamicImportReload(): void {
	const tag = "hcrDynamicImportReload";
	const fixture = "dynamicImport";
	const dir = freshDir(`${TMP}/${fixture}`);
	for (const name of ["app.ms", "note.ms", "dep.ms", "failing.ms"]) copy(`${FIXTURES}/${fixture}/${name}`, `${dir}/${name}`);
	copy(`${FIXTURES}/registrySupport.ms`, `${dir}/support.ms`);
	const edits = ["lazy.ms", "lazyEdit.ms", "lazyAgain.ms"];
	for (let i = 0; i < edits.length; i += 1) {
		copy(`${FIXTURES}/${fixture}/${edits[i]}`, `${dir}/lazy.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=g${i + 1}/module${sharedLibraryExt()}`],
			`generation ${i + 1} failed to build`);
	}
	runPrebuilt(tag, dir, ["lazy", "dep", "failing", "note", "support"], "DYN", [
		"DYN start app",
		"DYN g2: reloaded lazy",
		"DYN sync end",
		"DYN dep body",
		"DYN lazy body g2",
		"DYN lazy g2 g2 dep g2 dep",
		"DYN resumed lazy g3",
		"DYN g3: reloaded lazy",
		"DYN after g3 g3 g2 dep",
		"DYN failing body",
		"DYN first boom",
		"DYN second boom same",
		"DYN destroy lazy",
		"DYN destroy dep",
		"DYN destroy app",
	]);
}

const DYNAMIC_IMPORT_PINS = [
	"dynamicImportOrder", "dynamicImportConcurrent", "dynamicImportInitThrows", "dynamicImportCycle",
	"dynamicImportStaticDep", "dynamicImportDeinitOrder", "dynamicImportSpawn",
	"dynamicImportTla", "dynamicImportTlaDep", "dynamicImportTlaConcurrent", "dynamicImportTlaRejects",
	"dynamicImportTlaCycle", "dynamicImportTlaSpawn", "dynamicImportTlaDeinit",
];

function stdoutPins(source: string): string[] {
	const want: string[] = [];
	for (const line of lines(source)) {
		if (line.startsWith("// @stdout: ")) want.push(line.slice(12, line.length));
	}
	return want;
}

function runPinOnHost(tag: string, host: string, dir: string, entry: string, label: string): void {
	const main = read(`${dir}/${entry}`);
	const want = stdoutPins(main);
	put(`${dir}/${entry}`, "import { reload } from \"std/hcr\";\n" + main);
	const entryDir = entry.includes("/") ? `${dir}/${entry.slice(0, entry.lastIndexOf("/"))}` : dir;
	const entryFile = entry.includes("/") ? entry.slice(entry.lastIndexOf("/") + 1, entry.length) : entry;
	mustBuild(tag, entryDir, ["build", entryFile, "--hcr", `--output=run/module${sharedLibraryExt()}`], `${label}: the --hcr build failed`);
	const ran = execFileResult(host, ["run", "module"], entryDir);
	const seen: string[] = [];
	for (const line of lines(ran.output)) {
		if (line != "") seen.push(line);
	}
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, `${label}: the --hcr images did not print the pinned stdout`);
	}
}

function dynamicImportParity(): void {
	const tag = "hcrDynamicImportParity";
	const hostDir = freshDir(`${TMP}/dynamicImportHost`);
	const host = `${hostDir}/${platform == "windows" ? "host.exe" : "host"}`;
	copy(STD_HOST, `${hostDir}/host.cms`);
	mustBuild(tag, hostDir, ["build", "host.cms", `--output=${host}`], "thin host build failed");
	for (const pin of DYNAMIC_IMPORT_PINS) {
		const source = `${ROOT}/src/test/corpus/programs/${pin}`;
		const dir = freshDir(`${TMP}/${pin}`);
		for (const f of readDir(source)) copy(`${source}/${f}`, `${dir}/${f}`);
		runPinOnHost(tag, host, dir, "main.ms", pin);
	}
	const outside = freshDir(`${TMP}/dynamicImportOutside`);
	for (const sub of ["app", "shared"]) {
		ensureDir(`${outside}/${sub}`);
		for (const f of readDir(`${FIXTURES}/dynamicImportOutside/${sub}`)) copy(`${FIXTURES}/dynamicImportOutside/${sub}/${f}`, `${outside}/${sub}/${f}`);
	}
	runPinOnHost(tag, host, outside, "app/main.ms", "a module outside the project, so linked into the core");
	console.log(`ok   ${tag}`);
}

// ---- hcrJsInstanceFiles: a new instantiation in the app leaves the library's ES module alone ----

function jsInstanceFiles(): void {
	const tag = "hcrJsInstanceFiles";
	const dir = freshDir(`${TMP}/jsInstanceFiles`);
	copy(`${FIXTURES}/jsInstanceFiles/lib.ms`, `${dir}/lib.ms`);
	const first = "JS-INST first 1 7 own 2 own 1 made=4 counted=1";
	const second = "JS-INST second 1 true app 3 own 1 made=8 counted=2";
	const refusal = "invalid object conversion: Box<boolean> is not Box<int32>";
	const third = "JS-INST third #8";
	const fourth = "JS-INST fourth true false On:1";
	const edits = ["app.ms", "appSecondType.ms", "appWrongCast.ms", "appFirstUse.ms", "appLoweringHelpers.ms"];
	const wants = [[first], [first, second], [first, second, refusal], [first, second, third], [first, second, fourth]];
	const libOf: string[] = [];
	for (let i = 0; i < edits.length; i += 1) {
		copy(`${FIXTURES}/jsInstanceFiles/${edits[i]}`, `${dir}/app.ms`);
		mustBuild(tag, dir, ["build", "app.ms", "--target=js", "--split", `--output=tree${i}`], `split JS emission failed with ${edits[i]}`);
		libOf.push(read(`${dir}/tree${i}/lib.js`));
		const ran = msc(dir, ["run", "--target=js", "app.ms"]);
		const seen: string[] = [];
		for (const line of lines(both(ran))) {
			if (line.startsWith("JS-INST ")) seen.push(line);
			if (line.contains("invalid object conversion")) seen.push(line.slice(line.indexOf("invalid object conversion")));
		}
		if (seen.join("\n") != wants[i].join("\n") || succeeded(ran) != (edits[i] != "appWrongCast.ms")) {
			console.log(both(ran));
			failWith(tag, `${edits[i]} did not run as on the native target`);
		}
	}
	need(tag, libOf[0] != "", "the split tree has no lib.js");
	for (let i = 1; i < edits.length; i += 1) {
		need(tag, libOf[i] == libOf[0], `${edits[i]} changed the emitted file of the untouched module lib`);
	}
	const before = readDir(`${dir}/tree0/_inst`);
	for (const file of before) {
		need(tag, read(`${dir}/tree1/_inst/${file}`) == read(`${dir}/tree0/_inst/${file}`), `${edits[1]} changed the instance file ${file}`);
	}
	need(tag, readDir(`${dir}/tree1/_inst`).length > before.length, `${edits[1]} added no instance file`);
	console.log(`ok   ${tag}`);
}

function readUntil(child: ChildProcess, seen: string[], marker: string, limitMs: number): boolean {
	const deadline = performance.now() + limitMs;
	while (!seen[0].contains(marker) && performance.now() < deadline) {
		const got = child.read(ChildStream.Stdout, 200);
		if (!got.ok) continue;
		if (got.value.ended) break;
		seen[0] = seen[0] + got.value.data;
	}
	return seen[0].contains(marker);
}

function runKeys(): void {
	const tag = "hcrRunKeys";
	const globalCache = env.get("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	for (const key of ["R", "r", "q"]) {
		const dir = freshDir(`${TMP}/runKeys_${key}`);
		copy(`${FIXTURES}/runKeys/app.ms`, `${dir}/app.ms`);
		copy(`${FIXTURES}/runKeys/logic.ms`, `${dir}/logic.ms`);
		copy(`${FIXTURES}/runKeys/logicGrown.ms`, `${dir}/grown.txt`);
		const started = spawnChild(MSC, ["run", "--hcr", "app.ms"], { cwd: dir, mergeStderr: true });
		need(tag, started.ok, `cannot start ${MSC}`);
		if (!started.ok) continue;
		const child = started.value;
		const seen = [""];
		const asked = readUntil(child, seen, "HCR-KEYS reloaded 9", 120000);
		if (!asked) console.log(seen[0]);
		need(tag, asked, `key ${key}: the edited body did not reload into the running program`);
		need(tag, seen[0].contains("HCR-KEYS start 7"), `key ${key}: the program did not start on the first build`);
		if (key != "q") {
			child.write(`${key}\n`, 5000);
			const marker = key == "R" ? "HCR-KEYS start 9" : "watch: rebuilt on key r";
			const answered = readUntil(child, seen, marker, 120000);
			if (!answered) console.log(seen[0]);
			need(tag, answered, `key ${key}: no '${marker}' after the key`);
			if (key == "R") {
				need(tag, seen[0].contains("watch: restarting"), "key R: no restart notice");
				need(tag, seen[0].split("checked ").length == 3, "key R: the restart ran a build (a second 'checked N/N' appeared after the edit's own)");
			}
		}
		child.write("q\n", 5000);
		const ended = child.wait(30000);
		if (!ended.ok) console.log(seen[0]);
		need(tag, ended.ok, `key ${key}: q did not end msc`);
		readUntil(child, seen, "watch: quit", 2000);
		need(tag, seen[0].contains("watch: quit"), `key ${key}: q printed no 'watch: quit'`);
		child.close();
	}
	env.set("MSC_NO_GLOBAL_CACHE", globalCache);
	console.log(`ok   ${tag}`);
}


function eventsOf(path: string): string[] {
	const out: string[] = [];
	for (const line of lines(read(path))) {
		if (line != "") out.push(line);
	}
	return out;
}

function eventAt(events: string[], from: int32, needle: string): int32 {
	for (let i = from; i < events.length; i += 1) {
		if (events[i].contains(needle)) return i;
	}
	return -1;
}

function startEvents(tag: string, name: string, events: string): ChildProcess {
	const dir = freshDir(`${TMP}/${name}`);
	for (const f of readDir(`${FIXTURES}/runEvents`)) copy(`${FIXTURES}/runEvents/${f}`, `${dir}/${f}`);
	const started = spawnChild(MSC, ["run", "--hcr", `--events=${events}`, "app.ms"], { cwd: dir, mergeStderr: true });
	if (!started.ok) {
		console.log(`FAIL ${tag}: cannot start ${MSC}`);
		exit(1);
	}
	return started.value;
}

function runEvents(): void {
	const tag = "hcrRunEvents";
	const globalCache = env.get("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	const dir = `${TMP}/runEvents`;
	const child = startEvents(tag, "runEvents", "events.jsonl");
	const seen = [""];
	const stage = (marker: string, why: string): void => {
		const got = readUntil(child, seen, marker, 120000);
		if (!got) console.log(seen[0]);
		need(tag, got, why);
	};
	stage("EVENTS start 7 1", "the program did not start on the first build");
	copy(`${dir}/logicEdited.ms`, `${dir}/logic.ms`);
	stage("EVENTS reloaded 9", "the body edit did not reload");
	copy(`${dir}/logicBroken.ms`, `${dir}/logic.ms`);
	stage("stopping before codegen", "the type error did not stop the build");
	copy(`${dir}/modelGrown.ms`, `${dir}/model.ms`);
	copy(`${dir}/logicEdited.ms`, `${dir}/logic.ms`);
	stage("; press R to restart", "a field added to a live class did not ask for a restart");
	child.write("q\n", 5000);
	const ended = child.wait(30000);
	if (!ended.ok) console.log(seen[0]);
	need(tag, ended.ok, "q did not end msc");
	readUntil(child, seen, "watch: quit", 2000);
	child.close();

	const human = [
		"error: Type 'int32' is not assignable to type 'string'",
		`  --> ${dir}/logic.ms:1:42`,
		"    |",
		"1 | export function value(): string { return 1; }",
		`    | ${"".padStart(41, " ")}^`,
		"",
		"error: 1 type error(s) found, stopping before codegen",
	].join("\n");
	need(tag, seen[0].replaceAll("\r", "").contains(human), "the human type-error lines differ from the pinned rendering");

	const ev = eventsOf(`${dir}/events.jsonl`);
	for (const line of ev) {
		need(tag, line.startsWith("{\"v\":1,\"t\":") && line.endsWith("}"), `not an event envelope: ${line}`);
	}
	const first = eventAt(ev, 0, "\"event\":\"build.done\"");
	need(tag, first >= 0, "no build.done for the first build");
	const start2 = eventAt(ev, first + 1, "\"event\":\"build.start\"");
	need(tag, start2 > first, "no build.start for the body edit");
	need(tag, eventAt(ev, start2, "\"event\":\"build.start\",\"build\":2,\"changed\":[\"logic.ms\"]") > start2, "no build.start naming logic.ms as changed");
	const done2 = eventAt(ev, start2, "\"event\":\"build.done\"");
	need(tag, done2 > start2, "no build.done after the body edit");
	const reloaded = eventAt(ev, done2, "\"event\":\"reload\",\"source\":\"runtime\",\"kind\":\"reloaded\"");
	need(tag, reloaded > done2, "no runtime reload event of kind reloaded after the body edit");
	const failed = eventAt(ev, reloaded, "\"event\":\"build.failed\"");
	need(tag, failed > reloaded, "no build.failed for the type error");
	const located = `"file":"${dir}/logic.ms","line":1,"col":42,"severity":"error","message":"Type 'int32' is not assignable to type 'string'"`;
	need(tag, ev[failed].contains(located), `build.failed does not carry the diagnostic location: ${ev[failed]}`);
	const restart = eventAt(ev, failed, "\"event\":\"reload\",\"source\":\"runtime\",\"kind\":\"restartRequired\"");
	need(tag, restart > failed && ev[restart].contains("\"modules\":[\"model\"]") && ev[restart].contains("live values"), "no runtime restartRequired naming the model module and its live values");
	need(tag, eventAt(ev, restart, "\"event\":\"exit\",\"code\":") > restart, "no exit event");
	need(tag, seen[0].contains("watch: type 'Box'"), "the restart hint does not carry the engine's reason");

	const onStdout = startEvents(tag, "runEventsStdout", "-");
	const out = [""];
	const got = readUntil(onStdout, out, "EVENTS start 7 1", 120000);
	if (!got) console.log(out[0]);
	need(tag, got, "--events=- : the program did not start");
	onStdout.write("q\n", 5000);
	onStdout.wait(30000);
	readUntil(onStdout, out, "watch: quit", 2000);
	onStdout.close();
	need(tag, out[0].contains("{\"v\":1,\"t\":") && out[0].contains("\"event\":\"build.done\"") && out[0].contains("watch: build 0 built"), "--events=- : events and human lines are not both on stdout");

	const bad = startEvents(tag, "runEventsMalformed", "events.jsonl");
	const badSeen = [""];
	const up = readUntil(bad, badSeen, "EVENTS start 7 1", 120000);
	if (!up) console.log(badSeen[0]);
	need(tag, up, "malformed case: the program did not start");
	const verdicts = `${TMP}/runEventsMalformed/out/hcr/app.reload.jsonl`;
	need(tag, writeFile(verdicts, "this is not json\n").ok, `cannot write ${verdicts}`);
	readUntil(bad, badSeen, "is not JSON", 20000);
	const died = bad.wait(30000);
	bad.close();
	need(tag, badSeen[0].contains("app.reload.jsonl line 1 is not JSON"), `a malformed verdict line was not named: ${badSeen[0]}`);
	need(tag, died.ok && died.value.code == 1, "a malformed verdict line did not end msc with code 1");
	env.set("MSC_NO_GLOBAL_CACHE", globalCache);
	console.log(`ok   ${tag}`);
}
const CASES: { name: string, run: () => void }[] = [
	{ name: "hcrFsWatch", run: fsWatch },
	{ name: "hcrModuleAbi", run: moduleAbi },
	{ name: "hcrFirstWarmBuild", run: firstWarmBuild },
	{ name: "hcrTimeReportsPhaseC", run: timeReportsPhaseC },
	{ name: "hcrModuleLocalNames", run: localNames },
	{ name: "hcrWatchWarm", run: watchWarm },
	{ name: "hcrWatchGeneric", run: watchGeneric },
	{ name: "hcrNewInstance", run: newInstance },
	{ name: "hcrPrivateHelper", run: privateHelper },
	{ name: "hcrSubdirModule", run: subdirModule },
	{ name: "hcrReloadOff", run: reloadOff },
	{ name: "hcrCoreLinkClang", run: coreLinkClang },
	{ name: "hcrIndirect", run: indirect },
	{ name: "hcrSharedVariable", run: sharedVariable },
	{ name: "hcrNamespaceVariable", run: namespaceVariable },
	{ name: "hcrNamespaceShift", run: namespaceShift },
	{ name: "hcrEngine", run: engine },
	{ name: "hcrAsyncLoop", run: asyncLoop },
	{ name: "hcrLiftNames", run: liftNames },
	{ name: "hcrLiftKinds", run: liftKinds },
	{ name: "hcrRun", run: runCommand },
	{ name: "hcrStepCrash", run: stepCrash },
	{ name: "hcrUnchangedObjectKeepsImage", run: unchangedObjectKeepsImage },
	{ name: "hcrStepJoinCrash", run: stepJoinCrash },
	{ name: "hcrStepSpareCrash", run: stepSpareCrash },
	{ name: "hcrCrossImageNew", run: crossImageNew },
	{ name: "hcrGenericCtor", run: genericCtor },
	{ name: "hcrGenericOps", run: genericOps },
	{ name: "hcrGenericIdentity", run: genericIdentity },
	{ name: "hcrExitDestroy", run: exitDestroy },
	{ name: "hcrRetainReport", run: retainReport },
	{ name: "hcrRegistryVariables", run: registryVariables },
	{ name: "hcrModulePassReload", run: modulePassReload },
	{ name: "hcrLayoutReload", run: layoutReload },
	{ name: "hcrLayoutVariants", run: layoutVariants },
	{ name: "hcrRegistryGeneric", run: registryGeneric },
	{ name: "hcrModuleTdz", run: moduleTdz },
	{ name: "hcrFunctionValues", run: functionValues },
	{ name: "hcrDollarNames", run: dollarNames },
	{ name: "hcrInlineFunctions", run: inlineFunctions },
	{ name: "hcrFileDependency", run: fileDependency },
	{ name: "hcrCoreCell", run: coreCell },
	{ name: "hcrCoreOp", run: coreOp },
	{ name: "hcrCoreGenericInit", run: coreGenericInit },
	{ name: "hcrMacroHelper", run: macroHelper },
	{ name: "hcrOverloadCall", run: overloadCall },
	{ name: "hcrCoreConstant", run: coreConstant },
	{ name: "hcrCoreNative", run: coreNative },
	{ name: "hcrGlobalCell", run: globalCell },
	{ name: "hcrBorrowAcrossReload", run: borrowAcrossReload },
	{ name: "hcrWatchWarmDependency", run: watchWarmDependency },
	{ name: "hcrTypeInfoLocality", run: typeInfoLocality },
	{ name: "hcrWatchLink", run: watchLink },
	{ name: "hcrImageNameCollision", run: imageNameCollision },
	{ name: "hcrArrayOwner", run: arrayOwner },
	{ name: "hcrInstanceofReload", run: instanceofReload },
	{ name: "hcrAddedModule", run: addedModule },
	{ name: "hcrSameSecondEdit", run: sameSecondEdit },
	{ name: "hcrAndroidImages", run: androidImages },
	{ name: "hcrDynamicImportReload", run: dynamicImportReload },
	{ name: "hcrDynamicImportParity", run: dynamicImportParity },
	{ name: "hcrJsInstanceFiles", run: jsInstanceFiles },
	{ name: "hcrRunKeys", run: runKeys },
	{ name: "hcrRunEvents", run: runEvents },
	{ name: "hcrRunBound", run: runBound },
];
if (platform == "windows") CASES.push({ name: "hcrWindowsReload", run: windowsReload });

const SHARD = (env.get("HCR_SHARD") == "" ? "0/1" : env.get("HCR_SHARD")).split("/");
const SHARD_INDEX = SHARD[0].parseInt() as int32;
const SHARD_COUNT = SHARD.length == 2 ? SHARD[1].parseInt() as int32 : 0;
const ONLY = env.get("HCR_ONLY") == "" ? [] as string[] : env.get("HCR_ONLY").split(",");
if (SHARD_COUNT < 1 || SHARD_INDEX < 0 || SHARD_INDEX >= SHARD_COUNT) {
	console.log(`hcr: HCR_SHARD must be <index>/<count> with 0 <= index < count, got '${env.get("HCR_SHARD")}'`);
	exit(2);
}

console.log(`hcr: compiler under test = ${MSC}`);
ensureDir(TMP);
for (let i = 0; i < CASES.length; i++) {
	if (i % SHARD_COUNT != SHARD_INDEX) continue;
	if (ONLY.length > 0 && !ONLY.includes(CASES[i].name)) continue;
	let parkedCard = "";
	for (const p of PARKED) {
		if (p.name == CASES[i].name) parkedCard = p.card;
	}
	if (parkedCard != "") {
		console.log(`skip ${CASES[i].name}: parked on a compiler bug (${parkedCard})`);
		continue;
	}
	const t0 = performance.now();
	CASES[i].run();
	console.log(`time ${CASES[i].name} ${Math.round((performance.now() - t0) / 1000)}s`);
}
