// HCR runner: msc run src/test/hcr/run.ms --target=raiser, from the recompiler root.
// Env: MSC=<path to msc> (default: ./msc, else installed msc).
import { execFileResult, ExecFileResult, exit, env, cwd, platform } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, removeAll, copyFile } from "std/fs";

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

function msc(dir: string, args: string[]): ExecFileResult {
	return execFileResult(MSC, args, dir);
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

// ---- hcrModuleAbi: per-module object cache and ABI bundle classification ----

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
	const manifest = read(bundle);
	need(tag, manifest.contains("\"moduleId\": \"app\""), "app manifest missing");
	need(tag, manifest.contains("\"moduleId\": \"logic\""), "logic manifest missing");
	need(tag, manifest.contains("\"id\": \"logic::value#0\""), "logic slot identity is not project-relative");

	put(bundle, manifest.replace("\"gcMode\": \"orc\"", "\"gcMode\": \"drc\""));
	const stale = mustBuild(tag, work, quietBuild, "valid stale ABI bundle recovery failed");
	need(tag, stale.contains("HCR restart required: GC mode changed (drc -> orc)"), "stale bundle classification missing");

	copy(`${FIXTURES}/logicBodyEdit.ms`, `${work}/logic.ms`);
	const edit = mustBuild(tag, work, hcrBuild, "body-edit build failed");
	let ccCount = 0;
	let logicCompiled = false;
	let appCompiled = false;
	let appCached = false;
	for (const line of lines(edit)) {
		if (line.startsWith("    cc ")) {
			ccCount = ccCount + 1;
			if (line.contains("logic_x_ms")) logicCompiled = true;
			if (line.contains("app_x_ms")) appCompiled = true;
		}
		const t = line.trim();
		if (line != t && t.startsWith("cached ") && t.endsWith("app.ms")) appCached = true;
	}
	need(tag, ccCount == 1, `body edit compiled ${ccCount} modules, expected 1`);
	need(tag, logicCompiled, "logic object was not compiled");
	need(tag, !appCompiled, "unchanged app object was compiled");
	need(tag, appCached, "unchanged app object was not reported cached");
	need(tag, edit.contains("HCR reload module: implementation changed (logic)"), "body edit classification missing");
	need(tag, exists(`${work}/module.hcr`), "linked HCR image missing");

	copy(`${FIXTURES}/logicSignatureEdit.ms`, `${work}/logic.ms`);
	const signature = mustBuild(tag, work, hcrBuild, "signature-edit build failed");
	need(tag, signature.contains("HCR reload dependents: export signature changed (logic::value#0)"), "signature edit classification missing");

	const before = read(`${work}/module.hcr`);
	put(bundle, "{broken\n");
	const corrupt = msc(work, quietBuild);
	need(tag, !succeeded(corrupt), "corrupt current ABI bundle was accepted");
	need(tag, both(corrupt).contains("invalid current HCR ABI bundle 'module.hcr.hcrabi': invalid JSON"), "corrupt bundle diagnostic missing");
	need(tag, read(`${work}/module.hcr`) == before, "corrupt bundle replaced current image");
	console.log("ok   hcrModuleAbi");
}

// ---- hcrIndirect: cross-module calls lowered through module tables ----

interface Emitted {
	app: string;
	logic: string;
	dispatch: string;
	appImage: string;
	core: string;
}

function emitIndirect(dir: string, extra: string[]): Emitted {
	removeAll(`${dir}/out`);
	const args: string[] = ["build", "app.ms"];
	for (const a of extra) args.push(a);
	args.push("--emit=c");
	mustBuild("hcrIndirect", dir, args, `C emission failed (${extra.join(" ")})`);
	const debug = `${dir}/out/debug`;
	let app = "";
	let logic = "";
	let appImage = "";
	for (const e of readDir(debug)) {
		if (e.startsWith("_hcrimage_")) {
			if (e.endsWith("appOms.c")) appImage = read(`${debug}/${e}`);
			continue;
		}
		if (e.endsWith("appOms.c")) app = read(`${debug}/${e}`);
		if (e.endsWith("logicOms.c")) logic = read(`${debug}/${e}`);
	}
	return { app, logic, dispatch: read(`${debug}/_dispatch.c`), appImage, core: read(`${debug}/_hcrcore.c`) };
}

// The name between `prefix` and `suffix` on a whole line, when it is one identifier.
function declName(text: string, prefix: string, stem: string, suffixStart: string, suffixEnd: string): string {
	for (const line of lines(text)) {
		if (!line.startsWith(prefix + stem) || !line.endsWith(suffixEnd)) continue;
		const open = line.indexOf(suffixStart, prefix.length);
		if (open < 0) continue;
		const name = line.slice(prefix.length, open);
		let ident = true;
		for (let i = 0; i < name.length; i++) {
			const c = name.charAt(i);
			if (!((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_")) ident = false;
		}
		if (ident) return name;
	}
	return "";
}

function indirect(): void {
	const tag = "hcrIndirect";
	const dir = freshDir(`${TMP}/indirect`);
	for (const f of ["app.ms", "logic.ms", "shapes.ms", "host.ms", "hostCalls.h"]) copy(`${FIXTURES}/indirect/${f}`, `${dir}/${f}`);

	const plain = emitIndirect(dir, []);
	for (const c of [plain.app, plain.logic, plain.dispatch]) {
		need(tag, !c.contains("msHcr") && !c.contains("_ms_hcr"), "a build without --hcr emitted HCR indirection");
	}

	const hcr = emitIndirect(dir, ["--hcr"]);
	const value = declName(hcr.logic, "int32_t ", "value__", "(", "(void);");
	const base = declName(hcr.logic, "int32_t ", "base__", "(", "(void);");
	const pair = declName(hcr.logic, "void ", "pair__", "(", " __result, int32_t scale);");
	const tick = declName(hcr.logic, "int32_t ", "tick__", "(", "(void);");
	need(tag, value != "" && base != "" && pair != "" && tick != "", "logic exports not found in emitted C");
	need(tag, hcr.app.contains(`#define ${value} ((__typeof__(&${value}))_ms_hcr_m0->current[3])`),
		"cross-module call to logic::value is not lowered through its table slot");
	need(tag, hcr.app.contains("_ms_hcr_m0 = msHcrHandle(\"logic\");"), "app does not resolve the logic handle");
	need(tag, hcr.app.contains(`${value}()`), "app call site changed shape");
	need(tag, hcr.logic.contains("msHcrPublish(\"logic\", _ms_hcr_table, 4);"), "logic does not publish its table");
	need(tag, hcr.logic.contains(`(void*)&${base}, (void*)&${pair}, (void*)&${tick}, (void*)&${value}`), "logic table is not in manifest slot order");
	need(tag, !hcr.logic.contains(`#define ${base} `) && !hcr.logic.contains(`#define ${value} `), "same-module calls in logic are indirected");
	need(tag, hcr.logic.contains(`return (${base}() + offset__`), "same-module and private calls are not direct");
	need(tag, hcr.appImage.contains("msHcrCoreInit();"), "the app image DatInit does not initialize the core image first");
	need(tag, hcr.appImage.contains("MS_HCR_EXPORT void DatInit000(void) {"), "the app image does not export DatInit000");
	need(tag, hcr.core.contains("void msHcrCoreInit(void) {"), "the core dispatcher does not define msHcrCoreInit");
	let typeInfoMacro = false;
	for (const line of lines(hcr.app)) {
		if (line.contains("#define Square__") && line.contains("TypeInfo (*_ms_hcr_ti")) typeInfoMacro = true;
	}
	need(tag, typeInfoMacro, "app does not reach the shapes TypeInfo through the registry");
	need(tag, hcr.app.contains("msHcrTypeInfo(\"shapes\", \"Square__"), "app does not resolve the shapes TypeInfo by owner and name");
	need(tag, hcr.logic.contains("MS_HCR_EXPORT const char* HcrAbiKey000(void) { return \""), "logic does not export its ABI key");
	need(tag, hcr.app.contains("HcrImports000(void) { static const char* const imports[] = { \"logic\", \""), "app does not declare its import of logic with a key");
	sharedVariable();

	if (platform != "windows") {
		console.log(`ok   hcrIndirect (emission only: this runner has no host adapter for ${platform})`);
		return;
	}
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", "--output=g1/module.dll"], "HCR image link failed");
	for (const image of ["module.dll", "module.core.dll", "module.logic.dll", "module.shapes.dll"]) {
		need(tag, exists(`${dir}/g1/${image}`), `per-module image g1/${image} missing`);
	}
	copy(`${FIXTURES}/indirect/logicBodyEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", "--output=g2/module.dll"], "HCR rebuild after the logic edit failed");
	copy(`${FIXTURES}/indirect/logicExportEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, ["build", "app.ms", "--hcr", "--output=g3/module.dll"], "HCR rebuild after the logic export edit failed");
	mustBuild(tag, dir, ["build", "host.ms", "--output=host.exe"], "host build failed");
	const called = execFileResult(`${dir}/host.exe`,
		["g1/module.logic.dll", "g1/module.shapes.dll", "g1/module.dll", "--", "g2/module.logic.dll", "g3/module.logic.dll"], dir);
	const want = [
		"HCR-HOST gen1 hcrIndirectValue -> 37",
		"HCR-HOST gen1 hcrShapeValue -> 9",
		"HCR-HOST gen1 hcrErrorValue -> 1",
		"HCR-HOST gen1 hcrTickValue -> 1",
		"HCR-HOST key module.dll -> logic matches",
		"HCR-HOST staged logic -> 1",
		"HCR-HOST staged hcrIndirectValue -> 37",
		"HCR-HOST reloaded g2/module.logic.dll",
		"HCR-HOST gen2 hcrIndirectValue -> 163",
		"HCR-HOST gen2 hcrShapeValue -> 9",
		"HCR-HOST gen2 hcrErrorValue -> 1",
		"HCR-HOST gen2 hcrTickValue -> 11",
		"HCR-HOST rolled back logic",
		"HCR-HOST rollback hcrIndirectValue -> 37",
		"HCR-HOST key module.dll -> logic differs",
		"HCR-HOST rejected g3/module.logic.dll",
	];
	if (lines(both(called).trim()).join("\n") != want.join("\n")) {
		console.log(both(called));
		failWith(tag, "the host transaction (key check, stage, commit, rollback) did not produce the expected transitions");
	}
	console.log("ok   hcrIndirect");
	engine();
	windowsReload();
}

function engine(): void {
	const tag = "hcrEngine";
	const dir = freshDir(`${TMP}/engine`);
	for (const f of ["app.ms", "host.ms", "hostCalls.h", "handlerMisuse.ms"]) copy(`${FIXTURES}/engine/${f}`, `${dir}/${f}`);
	const misuse = msc(dir, ["build", "handlerMisuse.ms", "--hcr", "--emit=c"]);
	need(tag, !succeeded(misuse), "misused reload handlers were accepted");
	for (const diagnostic of [
		"@beforeReload handlers take no parameters",
		"@afterReload handlers return void",
		"@beforeReload names the handler's C symbol itself; drop @exportName",
	]) {
		need(tag, both(misuse).contains(diagnostic), `missing diagnostic: ${diagnostic}`);
	}
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
		mustBuild(tag, dir, ["build", "app.ms", "--hcr", `--output=${g[2]}/module.dll`], `HCR build of ${g[0]} + ${g[1]} failed`);
	}
	mustBuild(tag, dir, ["build", "host.ms", "--output=host.exe"], "thin host build failed");
	ensureDir(`${dir}/run`);
	for (const image of ["module.dll", "module.core.dll", "module.logic.dll", "module.lifecycle.dll", "module.dll.hcrabi"]) {
		copy(`${dir}/g1/${image}`, `${dir}/run/${image}`);
	}
	const ran = execFileResult(`${dir}/host.exe`, ["run", "module"], dir);
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
		"HCR-ENGINE truncated image: pending logic (cannot load run/module.logic.dll (error 193))",
		"HCR-ENGINE same truncated image: pending logic (run/module.logic.dll is not a loadable image yet)",
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
		"HCR-ENGINE after-reload handler throws: rejected lifecycle (the after-reload handler of module 'lifecycle' threw; rolled back lifecycle)",
		"HCR-ENGINE after rollback: value 10 tick 13 version 1",
		"HCR-ENGINE probe after rollback: instanceof true true scaled 70",
		"HCR-ENGINE lifecycle v1: destroy probe 8",
		"HCR-ENGINE lifecycle v1: destroy probe 7",
		"HCR-ENGINE added export, app not rebuilt: rejected (module 'app' was built against another export ABI of 'logic'; rebuild it)",
		"HCR-ENGINE after rejection: value 10 tick 14 version 1",
		"HCR-ENGINE state layout changed: restart required logic (the lifted state layout of module 'logic' changed)",
		"HCR-ENGINE after layout rejection: value 10 tick 15 version 1",
		"HCR-ENGINE class layout changed: restart required lifecycle (the layout of type 'Probe' in module 'lifecycle' changed)",
		"HCR-ENGINE after class layout rejection: value 10 tick 16 version 1",
		"HCR-ENGINE core changed: restart required (the core image changed (runtime, standard library or toolchain))",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "the engine did not produce the expected reload outcomes");
	}
	console.log("ok   hcrEngine");
}

function sharedVariable(): void {
	const dir = freshDir(`${TMP}/sharedVariable`);
	for (const f of ["app.ms", "logic.ms"]) copy(`${FIXTURES}/sharedVariable/${f}`, `${dir}/${f}`);
	const r = msc(dir, ["build", "app.ms", "--hcr", "--emit=c"]);
	need("hcrIndirect", !succeeded(r), "an exported variable shared across module images was accepted");
	need("hcrIndirect", both(r).contains("HCR cannot share exported variable 'logic::LIMIT' with module 'app' across module images"),
		"shared exported variable diagnostic missing");
}

// ---- hcrWindowsReload: single-image LoadLibrary reload, four generations ----

function windowsReload(): void {
	const tag = "hcrWindowsReload";
	const probeDir = `${ROOT}/examples/hcrProbe`;
	const out = "out/windows";
	const gen = `${out}/gen`;
	freshDir(`${probeDir}/${out}`);
	for (const g of ["g1", "g2", "g3", "g4"]) ensureDir(`${probeDir}/${gen}/${g}`);
	const builds = [["module.ms", "g1"], ["moduleBodyEdit.ms", "g2"], ["moduleLayoutEdit.ms", "g3"]];
	for (const b of builds) {
		const r = msc(ROOT, ["build", `examples/hcrProbe/${b[0]}`, "--hcr", `--output=examples/hcrProbe/${gen}/${b[1]}/module.dll`]);
		put(`${probeDir}/${out}/${b[1]}.build.log`, both(r));
	}
	put(`${probeDir}/${gen}/g4/module.dll`, read(`${probeDir}/${gen}/g2/module.dll`).byteSlice(0, 512));
	const host = msc(ROOT, ["build", "examples/hcrProbe/hostWindows.ms", `--output=examples/hcrProbe/${out}/hcrHostWindows.exe`]);
	put(`${probeDir}/${out}/host.build.log`, both(host));

	const run = execFileResult(`${probeDir}/${out}/hcrHostWindows.exe`,
		[`${gen}/g1/module.dll`, `${gen}/g2/module.dll`, `${gen}/g3/module.dll`, `${gen}/g4/module.dll`], probeDir);
	const probeOut = lines(run.output);
	let loaded = "";
	let reloaded = "";
	for (const line of probeOut) {
		const at = line.indexOf(" state=");
		if (at < 0) continue;
		if (line.startsWith("HCR-PROBE loaded ")) loaded = line.slice(at + 7, line.length);
		if (line.startsWith("HCR-PROBE reloaded ")) reloaded = line.slice(at + 7, line.length);
	}
	if (loaded == "" || loaded != reloaded) {
		console.log(both(run));
		failWith(tag, `lifted state pointer changed across reload: '${loaded}' -> '${reloaded}'`);
	}
	const want = [
		`HCR-PROBE call ${gen}/g1/module.dll -> 10`,
		`HCR-PROBE call ${gen}/g2/module.dll -> 40`,
		`HCR-PROBE rejected ${gen}/g3/module.dll (layout)`,
		`HCR-PROBE call ${gen}/g2/module.dll -> 60`,
		`HCR-PROBE rejected ${gen}/g4/module.dll (load)`,
		`HCR-PROBE call ${gen}/g2/module.dll -> 80`,
	];
	for (const w of want) {
		let found = false;
		for (const line of probeOut) {
			if (line == w) found = true;
		}
		if (!found) {
			console.log(both(run));
			failWith(tag, `missing line: ${w}`);
		}
	}
	need(tag, run.errorOutput.contains("incompatible state layout change"), "missing loud layout diagnostic");
	need(tag, run.errorOutput.contains("LoadLibraryA failed"), "missing loud bad-image diagnostic");
	console.log("ok   hcrWindowsReload");
}

console.log(`hcr: compiler under test = ${MSC}`);
ensureDir(TMP);
moduleAbi();
coreLinkClang();
indirect();
