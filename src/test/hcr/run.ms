// HCR runner: msc run --target=raiser src/test/hcr/run.ms, from the recompiler root.
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

const WATCH_BACKEND = platform == "windows" || platform == "linux";
const WATCH_CARD = "inbox card 2026-10-03-macos-fs-watch-backend.md";
const WATCHING = ["hcrRun", "hcrSubdirModule", "hcrFileDependency", "hcrNewInstance", "hcrPrivateHelper", "hcrStepCrash"];
let CURRENT = "";

function msc(dir: string, args: string[]): ExecFileResult {
	if (!WATCH_BACKEND && args.length > 1 && args[0] == "run" && args.includes("--hcr")) {
		failWith(CURRENT, `runs msc run --hcr, which needs a file-watch backend that ${platform} lacks; list it in WATCHING (${WATCH_CARD})`);
	}
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

function linkKeys(dir: string): string[] {
	const cache = `${dir}/out/debug/.cache`;
	const keys: string[] = [];
	for (const e of readDir(cache)) {
		if (e.startsWith("link.") && e.endsWith(".cache")) keys.push(`${e}\n${read(`${cache}/${e}`)}`);
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
	const cold = linkKeys(dir);
	copy(`${FIXTURES}/logicBodyEdit.ms`, `${dir}/logic.ms`);
	mustBuild(tag, dir, build, "body-edit build failed");
	let relinked = 0;
	for (const key of linkKeys(dir)) {
		if (!cold.includes(key)) relinked += 1;
	}
	need(tag, cold.length > 0, "the cold build left no link keys");
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

	if (platform != "windows" && platform != "linux") {
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
		"HCR-ENGINE class layout changed: restart required lifecycle",
		"HCR-ENGINE after class layout rejection: value 10 tick 16 version 1",
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
		for (const d of [`${ended}/core`, alive, foreign]) ensureDir(d);
		for (const f of [`${ended}/core/app.core${sharedLibraryExt()}`, `${alive}/keep.txt`, `${foreign}/keep.txt`]) put(f, "x");
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
		need(tag, !exists(ended), "the image copies of an ended run survived the next start");
		need(tag, exists(`${alive}/keep.txt`), "the start removed the copies of a live process");
		need(tag, exists(`${foreign}/keep.txt`), "the start removed a directory that is not a run");
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
		"STEP rolled back logic fatal then 2",
		"STEP rolled back logic fault then 2",
		"STEP rolled back logic exception then 2",
		"STEP reloaded 3",
	];
	if (!succeeded(ran) || seen.join("\n") != want.join("\n")) {
		console.log(both(ran));
		failWith(tag, "a crash inside step() did not roll back to the previous generation and keep running");
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
		if (f.endsWith("ZappOms.c")) app = f;
		if (f.endsWith("ZlogicOms.c")) logic = f;
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

const CASES: { name: string, run: () => void }[] = [
	{ name: "hcrFsWatch", run: fsWatch },
	{ name: "hcrModuleAbi", run: moduleAbi },
	{ name: "hcrFirstWarmBuild", run: firstWarmBuild },
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
	{ name: "hcrEngine", run: engine },
	{ name: "hcrAsyncLoop", run: asyncLoop },
	{ name: "hcrLiftNames", run: liftNames },
	{ name: "hcrLiftKinds", run: liftKinds },
	{ name: "hcrRun", run: runCommand },
	{ name: "hcrStepCrash", run: stepCrash },
	{ name: "hcrRegistryVariables", run: registryVariables },
	{ name: "hcrRegistryGeneric", run: registryGeneric },
	{ name: "hcrFunctionValues", run: functionValues },
	{ name: "hcrFileDependency", run: fileDependency },
	{ name: "hcrWatchWarmDependency", run: watchWarmDependency },
	{ name: "hcrTypeInfoLocality", run: typeInfoLocality },
	{ name: "hcrImageNameCollision", run: imageNameCollision },
	{ name: "hcrArrayOwner", run: arrayOwner },
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
	if (!WATCH_BACKEND && WATCHING.includes(CASES[i].name)) {
		console.log(`skip ${CASES[i].name}: needs a file-watch backend, none on ${platform} (${WATCH_CARD})`);
		continue;
	}
	CURRENT = CASES[i].name;
	const t0 = performance.now();
	CASES[i].run();
	console.log(`time ${CASES[i].name} ${Math.round((performance.now() - t0) / 1000)}s`);
}
