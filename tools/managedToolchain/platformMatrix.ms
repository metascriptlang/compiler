import { argv, cwd, env, platform, exit, spawn, ChildStream, ProcessErrorKind } from "std/process";
import { appendFile, ensureDir, exists, readFile, readDir, removeAll } from "std/fs";
import { join } from "std/fs/path";

// msc run tools/managedToolchain/platformMatrix.ms build --out=<dir> --host=<name> --hostTarget=<target> [--bundle=<dir>] [--targets=a,b] [--consumers=x,y] [--compilers=zig,bundle]
// msc run tools/managedToolchain/platformMatrix.ms run --out=<dir with art/ and cells.tsv> --host=<name> --hostTarget=<target>
// msc run tools/managedToolchain/platformMatrix.ms summary --out=<dir of *.tsv>

struct Target {
	name: string;
	os: string;
	cpu: string;
	exe: string;
	lib: string;
	selector: boolean;
}

struct Consumer {
	name: string;
	source: string;
	flags: string;
	kind: string;
	expect: string;
	code: int32;
}

struct Captured {
	code: int64;
	out: string;
	err: string;
	timedOut: boolean;
	seconds: number;
}

const TARGETS: Target[] = [
	{ name: "macos-arm64", os: "macos", cpu: "arm64", exe: "", lib: "dylib", selector: true },
	{ name: "macos-x64", os: "macos", cpu: "amd64", exe: "", lib: "dylib", selector: true },
	{ name: "linux-glibc-x86_64", os: "linux", cpu: "amd64", exe: "", lib: "so", selector: true },
	{ name: "linux-glibc-arm64", os: "linux", cpu: "arm64", exe: "", lib: "so", selector: true },
	{ name: "linux-musl-x86_64", os: "", cpu: "", exe: "", lib: "so", selector: false },
	{ name: "windows-x64", os: "windows", cpu: "amd64", exe: ".exe", lib: "dll", selector: true },
	{ name: "windows-arm64", os: "windows", cpu: "arm64", exe: ".exe", lib: "dll", selector: true },
	{ name: "wasm32-wasi", os: "wasm", cpu: "", exe: ".wasm", lib: "", selector: true },
];

const HELLO = "matrix-hello 42";
const CRYPTO = "matrix-crypto ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 11a25e88658143a853d280bf77f81ff3 6e9ef29b75fffc5b7abae527d58fdadb2fe42e7219011976917343065f58ed4a";
const THREADS = "matrix-threads 699103 498503 297903";

const CONSUMERS: Consumer[] = [
	{ name: "hello", source: "hello.ms", flags: "", kind: "exe", expect: HELLO, code: 3 },
	{ name: "threads", source: "threads.ms", flags: "", kind: "exe", expect: THREADS, code: 0 },
	{ name: "crypto", source: "crypto.ms", flags: "", kind: "exe", expect: CRYPTO, code: 0 },
	{ name: "cCompanion", source: "cCompanion.ms", flags: "", kind: "exe", expect: "matrix-c 1428", code: 0 },
	{ name: "cppCompanion", source: "cppCompanion.ms", flags: "", kind: "exe", expect: "matrix-cpp 48", code: 0 },
	{ name: "sharedLibrary", source: "sharedLibrary.ms", flags: "--app=lib", kind: "lib", expect: "matrix-lib 42", code: 0 },
	{ name: "debugLine", source: "debugLine.ms", flags: "", kind: "debug", expect: "matrix-debug 41", code: 0 },
	{ name: "helloRelease", source: "hello.ms", flags: "--release", kind: "exe", expect: HELLO, code: 3 },
	{ name: "cryptoRelease", source: "crypto.ms", flags: "--release", kind: "exe", expect: CRYPTO, code: 0 },
	{ name: "cryptoDanger", source: "crypto.ms", flags: "--danger", kind: "exe", expect: CRYPTO, code: 0 },
	{ name: "cryptoLtoFull", source: "crypto.ms", flags: "--danger --lto=full", kind: "exe", expect: CRYPTO, code: 0 },
	{ name: "sanAddress", source: "cCompanion.ms", flags: "--sanitize=address", kind: "exe", expect: "matrix-c 1428", code: 0 },
	{ name: "sanUndefined", source: "cCompanion.ms", flags: "--sanitize=undefined", kind: "exe", expect: "matrix-c 1428", code: 0 },
	{ name: "sanThread", source: "threads.ms", flags: "--sanitize=thread", kind: "exe", expect: THREADS, code: 0 },
	{ name: "hcr", source: "hcr.ms", flags: "--hcr", kind: "hcr", expect: "matrix-hcr 42", code: 0 },
];

const BUILD_LIMIT_MS = 1500000;
const RUN_LIMIT_MS = 120000;
const WASI_RUNNER = "const {WASI}=require('node:wasi');const fs=require('fs');const w=new WASI({version:'preview1',args:['x'],env:{},returnOnExit:true});WebAssembly.instantiate(fs.readFileSync(process.argv[1]),w.getImportObject()).then(m=>{process.exitCode=w.start(m.instance);});";
const LIB_LOADER = "import ctypes,sys;l=ctypes.CDLL(sys.argv[1]);print('matrix-lib',l.matrixLibraryValue())";

function capture(file: string, args: string[], limitMs: number): Captured {
	const started = performance.now();
	const child = spawn(file, args);
	if (!child.ok) {
		return { code: -1, out: "", err: child.error.message, timedOut: false, seconds: 0 };
	}
	const proc = child.value;
	proc.closeStdin();
	let out = "";
	let err = "";
	let outEnded = false;
	let errEnded = false;
	let timedOut = false;
	while ((!outEnded || !errEnded) && !timedOut) {
		if (performance.now() - started > limitMs) { timedOut = true; break; }
		if (!outEnded) {
			const got = proc.read(ChildStream.Stdout, 20);
			if (got.ok) { out += got.value.data; outEnded = got.value.ended; }
			else if (got.error.kind != ProcessErrorKind.Timeout && got.error.kind != ProcessErrorKind.OutputOverflow) { outEnded = true; }
		}
		if (!errEnded) {
			const got = proc.read(ChildStream.Stderr, 20);
			if (got.ok) { err += got.value.data; errEnded = got.value.ended; }
			else if (got.error.kind != ProcessErrorKind.Timeout && got.error.kind != ProcessErrorKind.OutputOverflow) { errEnded = true; }
		}
	}
	if (timedOut) { proc.kill(); }
	let status = proc.wait(20);
	let spins = 0;
	while (!status.ok && status.error.kind == ProcessErrorKind.Timeout && spins < 500) {
		status = proc.wait(20);
		spins += 1;
	}
	proc.close();
	const seconds = (performance.now() - started) / 1000;
	if (!status.ok) { return { code: -2, out, err, timedOut, seconds }; }
	const code = status.value.signal != 0 ? -(status.value.signal as int64) : (status.value.code as int64);
	return { code, out, err, timedOut, seconds };
}

function options(): Record<string, string> {
	const found: Record<string, string> = {};
	for (const arg of argv.slice(2)) {
		if (!arg.startsWith("--")) { continue; }
		const at = arg.indexOf("=");
		if (at < 0) { found[arg.slice(2, arg.length)] = "true"; }
		else { found[arg.slice(2, at)] = arg.slice(at + 1, arg.length); }
	}
	return found;
}

function mscPath(): string {
	const chosen = env.get("MSC") ?? "";
	if (chosen != "") { return chosen; }
	const home = env.get("HOME") ?? env.get("USERPROFILE") ?? "";
	return `${home}/.metascript/bin/msc${platform == "windows" ? ".exe" : ""}`;
}

function oneLine(text: string, limit: number): string {
	let flat = text.trim().split("\n").join("\\n").split("\r").join("").split("\t").join(" ");
	if (flat.length > limit) { flat = flat.slice(0, limit as int32); }
	return flat;
}

function firstError(text: string): string {
	const lines = text.split("\n");
	for (const line of lines) {
		if (line.contains("link failed") || line.contains("compile failed") || line.contains("(exit")) { continue; }
		if (line.contains("error") || line.contains("Error") || line.contains("undefined") || line.contains("cannot")) { return oneLine(line, 220); }
	}
	for (const line of lines) { if (line.contains("error")) { return oneLine(line, 220); } }
	const tail = text.trim().split("\n");
	return oneLine(tail.length > 0 ? tail[tail.length - 1] : "", 220);
}

function targetNamed(name: string): Target | null {
	for (const target of TARGETS) { if (target.name == name) { return target; } }
	return null;
}

function listOption(value: string): string[] {
	if (value == "") { return []; }
	return value.split(",");
}

function note(path: string, fields: string[]): void {
	const wrote = appendFile(path, fields.join("\t") + "\n");
	if (!wrote.ok) { throw new Error(`cannot write ${path}`); }
}

function runnerFor(hostTarget: string, target: string): string {
	if (target == hostTarget) { return "native"; }
	if (hostTarget == "macos-arm64" && target == "macos-x64") { return "rosetta"; }
	if (hostTarget == "macos-arm64" && target == "wasm32-wasi") { return "wasi"; }
	return "";
}

function runnerReason(hostTarget: string, target: string): string {
	if (target == "linux-glibc-x86_64") { return "built, not run (rtx offline)"; }
	if (target == "windows-arm64") { return "built, not run (no windows arm64 host)"; }
	if (target == "linux-musl-x86_64") { return "no CLI selector"; }
	return `built, not run (not runnable on ${hostTarget})`;
}

function present(path: string, needle: string): boolean {
	const found = capture("grep", ["-a", "-c", needle, path], 60000);
	return found.code == 0;
}

function debugKind(artifact: string, target: string): string {
	if (target.startsWith("macos")) {
		if (exists(artifact + ".dSYM")) { return "dSYM"; }
		const table = capture("nm", ["-pa", artifact], 60000);
		if (table.code == 0 && table.out.contains(" OSO ")) { return "debug-map-only (no dSYM)"; }
		return "none";
	}
	if (present(artifact, "\\.debug_info")) { return "DWARF"; }
	if (present(artifact, "RSDS")) { return "CodeView"; }
	return "none";
}

function runArtifact(consumer: Consumer, artifact: string, runner: string, target: string): Captured {
	if (consumer.kind == "lib") {
		if (runner == "rosetta") { return capture("arch", ["-x86_64", "/usr/bin/python3", "-I", "-c", LIB_LOADER, artifact], RUN_LIMIT_MS); }
		return capture(platform == "windows" ? "python" : "python3", ["-I", "-c", LIB_LOADER, artifact], RUN_LIMIT_MS);
	}
	if (runner == "wasi") { return capture("node", ["-e", WASI_RUNNER, artifact], RUN_LIMIT_MS); }
	if (runner == "rosetta") { return capture("arch", ["-x86_64", artifact], RUN_LIMIT_MS); }
	return capture(artifact, [], RUN_LIMIT_MS);
}

function runCell(results: string, host: string, consumer: Consumer, target: string, compiler: string, artifact: string, runner: string): void {
	const ran = runArtifact(consumer, artifact, runner, target);
	const observed = `rc=${ran.code} out=${oneLine(ran.out, 200)}`;
	const label = runner == "native" ? host : `${host}:${runner}`;
	if (ran.timedOut) {
		note(results, [consumer.name, target, compiler, "run", host, "FAIL", String(ran.seconds), observed, "timeout"]);
		return;
	}
	const good = ran.code == consumer.code && ran.out.trim() == consumer.expect;
	const why = good ? "" : `expected rc=${consumer.code} out=${consumer.expect}; stderr: ${oneLine(ran.err, 160)}`;
	note(results, [consumer.name, target, compiler, "run", host, good ? "ok" : "FAIL", String(ran.seconds), observed, why]);
	if (consumer.kind == "debug" && runner == "native") {
		note(results, [consumer.name, target, compiler, "debug", host, "info", "0", debugKind(artifact, target), ""]);
	}
}

function buildCell(out: string, results: string, cells: string, host: string, hostTarget: string, bundle: string, consumer: Consumer, target: Target, compiler: string): void {
	if (!target.selector) {
		note(results, [consumer.name, target.name, compiler, "build", host, "n/a", "0", "", "no CLI selector"]);
		return;
	}
	if (consumer.kind == "lib" && target.lib == "") {
		note(results, [consumer.name, target.name, compiler, "build", host, "n/a", "0", "", "no shared library on wasm32-wasi"]);
		return;
	}
	if (compiler == "bundle" && (bundle == "" || !exists(bundle))) {
		note(results, [consumer.name, target.name, compiler, "build", host, "n/a", "0", "", "no host bundle (the only bundle is aarch64-macos)"]);
		return;
	}
	if (consumer.kind == "hcr" && target.name != hostTarget) {
		note(results, [consumer.name, target.name, compiler, "build", host, "n/a", "0", "", "hcr runs on its own host only"]);
		return;
	}
	const native = target.name == hostTarget;
	const ext = consumer.kind == "lib" ? "." + target.lib : target.exe;
	const dir = `${out}/art/${target.name}/${compiler}`;
	ensureDir(dir);
	const artifact = join(dir, consumer.name + ext);
	const sourcePath = `${cwd()}/tools/managedToolchain/matrix/${consumer.source}`;
	const args: string[] = [consumer.kind == "hcr" ? "run" : "build"];
	for (const flag of consumer.flags.split(" ")) { if (flag != "") { args.push(flag); } }
	if (!native) {
		args.push(`--os=${target.os}`);
		if (target.cpu != "") { args.push(`--cpu=${target.cpu}`); }
	}
	if (compiler == "zig") { args.push("--cc=zig"); env.delete("MSC_NATIVE_TOOLCHAIN"); }
	else { env.set("MSC_NATIVE_TOOLCHAIN", bundle); }
	args.push(sourcePath);
	if (consumer.kind != "hcr") { args.push(`--output=${artifact}`); }
	const msc = mscPath();
	const built = capture(msc, args, BUILD_LIMIT_MS);
	if (consumer.kind == "hcr") {
		const good = built.code == consumer.code && built.out.contains(consumer.expect);
		note(results, [consumer.name, target.name, compiler, "run", host, good ? "ok" : "FAIL", String(built.seconds), `rc=${built.code} out=${oneLine(built.out, 200)}`, good ? "" : firstError(built.err + built.out)]);
		return;
	}
	if (built.code != 0 || !exists(artifact)) {
		note(results, [consumer.name, target.name, compiler, "build", host, "FAIL", String(built.seconds), "", built.timedOut ? "timeout" : firstError(built.err + built.out)]);
		return;
	}
	note(results, [consumer.name, target.name, compiler, "build", host, "ok", String(built.seconds), "", ""]);
	note(cells, [consumer.name, target.name, compiler, `art/${target.name}/${compiler}/${consumer.name}${ext}`]);
	const runner = runnerFor(hostTarget, target.name);
	if (runner == "") {
		note(results, [consumer.name, target.name, compiler, "run", host, "n/a", "0", "", runnerReason(hostTarget, target.name)]);
		return;
	}
	runCell(results, host, consumer, target.name, compiler, artifact, runner);
}

function coldCell(out: string, results: string, host: string, hostTarget: string, bundle: string, target: Target, compiler: string): void {
	if (!target.selector || (compiler == "bundle" && (bundle == "" || !exists(bundle)))) { return; }
	const cache = `${out}/cold/${target.name}/${compiler}`;
	removeAll(cache);
	ensureDir(cache);
	const artifact = join(cache, "helloCold" + target.exe);
	const args: string[] = ["build", `${cwd()}/tools/managedToolchain/matrix/hello.ms`, `--output=${artifact}`, `--cache-dir=${cache}`, "--no-global-cache", "--force"];
	if (target.name != hostTarget) {
		args.push(`--os=${target.os}`);
		if (target.cpu != "") { args.push(`--cpu=${target.cpu}`); }
	}
	if (compiler == "zig") { args.push("--cc=zig"); env.delete("MSC_NATIVE_TOOLCHAIN"); }
	else { env.set("MSC_NATIVE_TOOLCHAIN", bundle); }
	const built = capture(mscPath(), args, BUILD_LIMIT_MS);
	const good = built.code == 0 && exists(artifact);
	note(results, ["helloCold", target.name, compiler, "build", host, good ? "ok" : "FAIL", String(built.seconds), "", good ? "" : firstError(built.err + built.out)]);
}

function build(opts: Record<string, string>): void {
	const out = opts["out"] ?? "";
	const host = opts["host"] ?? "";
	const hostTarget = opts["hostTarget"] ?? "";
	if (out == "" || host == "" || hostTarget == "") { throw new Error("build needs --out, --host and --hostTarget"); }
	ensureDir(out);
	const results = join(out, `${host}.tsv`);
	const cells = join(out, `cells-${host}.tsv`);
	const bundle = opts["bundle"] ?? "";
	const targets = listOption(opts["targets"] ?? "");
	const only = listOption(opts["consumers"] ?? "");
	const compilers = listOption(opts["compilers"] ?? "");
	for (const target of TARGETS) {
		if (targets.length > 0 && !targets.includes(target.name)) { continue; }
		for (const compiler of compilers.length > 0 ? compilers : ["zig", "bundle"]) {
			if (only.length == 0 || only.includes("helloCold")) { coldCell(out, results, host, hostTarget, bundle, target, compiler); }
			for (const consumer of CONSUMERS) {
				if (only.length > 0 && !only.includes(consumer.name)) { continue; }
				buildCell(out, results, cells, host, hostTarget, bundle, consumer, target, compiler);
			}
		}
	}
}

function consumerNamed(name: string): Consumer {
	for (const consumer of CONSUMERS) { if (consumer.name == name) { return consumer; } }
	throw new Error(`unknown consumer ${name}`);
}

function runBuilt(opts: Record<string, string>): void {
	const out = opts["out"] ?? "";
	const host = opts["host"] ?? "";
	const hostTarget = opts["hostTarget"] ?? "";
	if (out == "" || host == "" || hostTarget == "") { throw new Error("run needs --out, --host and --hostTarget"); }
	const results = join(out, `run-${host}.tsv`);
	for (const name of readDir(out)) {
		if (!name.startsWith("cells-") || !name.endsWith(".tsv")) { continue; }
		const text = readFile(join(out, name));
		if (!text.ok) { continue; }
		for (const line of text.value.split("\n")) {
			const f = line.split("\t");
			if (f.length < 4) { continue; }
			const runner = runnerFor(hostTarget, f[1]);
			if (runner == "" || f[1] == opts["skipTarget"]) { continue; }
			runCell(results, host, consumerNamed(f[0]), f[1], f[2], join(out, f[3]), runner);
		}
	}
}

function rowOf(rows: Record<string, string[]>, key: string): string[] {
	return rows[key] ?? [];
}

function cellText(rows: Record<string, string[]>, consumer: string, target: string, compiler: string): string {
	const run = rowOf(rows, `${consumer}|${target}|${compiler}|run`);
	const built = rowOf(rows, `${consumer}|${target}|${compiler}|build`);
	if (run.length > 0) {
		if (run[5] == "ok") { return "ok"; }
		if (run[5] == "n/a") { return built.length > 0 && built[5] == "ok" ? `ok-build(${run[8]})` : `n/a(${run[8]})`; }
		return `FAIL(run: ${oneLine(run[8], 70)})`;
	}
	if (built.length == 0) { return "-"; }
	if (built[5] == "ok") { return "ok-build"; }
	if (built[5] == "n/a") { return `n/a(${built[8]})`; }
	return `FAIL(${oneLine(built[8], 70)})`;
}

function summary(opts: Record<string, string>): void {
	const out = opts["out"] ?? "";
	const rows: Record<string, string[]> = {};
	const keys: string[] = [];
	for (const name of readDir(out)) {
		if (!name.endsWith(".tsv") || name.startsWith("cells-")) { continue; }
		const text = readFile(join(out, name));
		if (!text.ok) { continue; }
		for (const line of text.value.split("\n")) {
			const f = line.split("\t");
			if (f.length < 9) { continue; }
			const key = `${f[0]}|${f[1]}|${f[2]}|${f[3]}`;
			if (rowOf(rows, key).length == 0) { keys.push(key); }
			rows[key] = f;
		}
	}
	const seen: string[] = [];
	for (const key of keys) {
		const f = rowOf(rows, key);
		const pair = `${f[0]}|${f[1]}`;
		if (f[3] == "debug" || seen.includes(pair)) { continue; }
		seen.push(pair);
		console.log(`${f[0]} ${f[1]}: zig=${cellText(rows, f[0], f[1], "zig")} bundle=${cellText(rows, f[0], f[1], "bundle")}`);
	}
	for (const target of TARGETS) {
		let zigTotal: number = 0;
		let bundleTotal: number = 0;
		let count = 0;
		for (const consumer of CONSUMERS) {
			const z = rowOf(rows, `${consumer.name}|${target.name}|zig|build`);
			const b = rowOf(rows, `${consumer.name}|${target.name}|bundle|build`);
			if (z.length > 0 && b.length > 0 && z[5] == "ok" && b[5] == "ok") {
				zigTotal += parseFloat(z[6]);
				bundleTotal += parseFloat(b[6]);
				count += 1;
			}
		}
		if (count > 0) { console.log(`build time ${target.name}: bundle/zig ${(bundleTotal / zigTotal).toFixed(2)} over ${count} builds (${bundleTotal.toFixed(0)} s / ${zigTotal.toFixed(0)} s)`); }
		const zc = rowOf(rows, `helloCold|${target.name}|zig|build`);
		const bc = rowOf(rows, `helloCold|${target.name}|bundle|build`);
		if (zc.length > 0 && bc.length > 0 && zc[5] == "ok" && bc[5] == "ok") {
			console.log(`cold hello ${target.name}: zig ${parseFloat(zc[6]).toFixed(1)} s, bundle ${parseFloat(bc[6]).toFixed(1)} s`);
		}
	}
}

const mode = argv.length > 1 ? argv[1] : "";
const opts = options();
if (mode == "build") { build(opts); }
else if (mode == "run") { runBuilt(opts); }
else if (mode == "summary") { summary(opts); }
else { console.log("usage: platformMatrix.ms build|run|summary --out=<dir> --host=<name> --hostTarget=<target> [--bundle=<dir>] [--targets=..] [--consumers=..] [--compilers=..]"); exit(2); }
