import { compileRaiser, runRaiser, setDiagnosticHook } from "../compiler/compile";
import { setRecoverableBuild, BUILD_STOPPED } from "../compiler/io";
import { CliOptions, newCliOptions } from "../compiler/options";
import { BuildSession, createBuildSession, holdsBuildState } from "../compiler/buildSession";
import { ModuleError, ErrorSeverity } from "../module/graph";
import { RaiserModule } from "../raiser/module";
import { RaiserContext } from "../raiser/context";
import { RaiserValue, RaiserValueKind } from "../raiser/value";
import { RaiserHostFn, RaiserHostValue, boxVoid, copyToHost, copyToVm } from "../raiser/marshal";
import { registerHostFn, routeHostFnThroughSystem, raiseFromHost, activeHostArrayHeap, activeHostObjectHeap, setActiveHostHeaps } from "../raiser/hostRegistry";
import { RaiserVM, RaiserInPlaceHostFn, registerInPlaceHostFn, vmCallHeld, vmDumpStack, vmReleaseRun, vmRunDueTimers, vmNextTimerDelayMs } from "../raiser/vm";
import { liveCellBlocks } from "../raiser/memory";
import { ledgerAudits } from "../raiser/ledger";
import { setHostRuntimeDir, resolveRuntimeDir } from "../utils/path";
import { System, machineSystem, activeSystem, setActiveSystem } from "../utils/system";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";
import { IoError, notFound } from "std/io/errors";
import { Buffer } from "std/core/buffer";
import { join } from "std/fs/path";

export interface Diagnostic {
	file: string;
	line: int32;
	column: int32;
	message: string;
	severity: ErrorSeverity;
}

export interface Evaluation {
	output: string;
	exitCode: int32;
	warnings: Diagnostic[];
}

export interface Interpreter {
	opts: CliOptions;
	session: BuildSession;
	run: RaiserContext | null;
	output: string[];
	system: System | null;
}

export interface Routine {
	name: string;
	mod: RaiserModule;
	funcIdx: int32;
	arity: int32;
}

export { RaiserValue, RaiserValueKind } from "../raiser/value";
export { System, machineSystem } from "../utils/system";
export {
	RaiserVM,
	RaiserInPlaceHostFn,
	hostArgCount,
	hostArgInt,
	hostArgFloat,
	hostArgBool,
	hostArgString,
	hostArg,
	hostReturnInt,
	hostReturnFloat,
	hostReturnBool,
	hostReturnString,
	hostReturn,
} from "../raiser/vm";
export {
	RaiserHostFn,
	RaiserHostValue,
	boxInt,
	boxFloat,
	boxString,
	boxBool,
	boxVoid,
	unboxInt,
	unboxFloat,
	unboxString,
	unboxBool,
	hostValue,
	hostString,
	hostObject,
	hostArray,
	field,
	length,
	at,
	text,
} from "../raiser/marshal";

function insideRoot(path: string, roots: string[]): boolean {
	const spelled = path.replaceAll("\\", "/");
	for (const root of roots) {
		if (spelled == root || spelled.startsWith(`${root}/`)) return true;
	}
	return false;
}

function readingRuntimeFromMachine(system: System, runtimeRoots: string[]): System {
	const machine = machineSystem();
	const roots: string[] = [];
	for (const root of runtimeRoots) roots.push(root.replaceAll("\\", "/"));
	const fromMachine = (path: string): boolean => insideRoot(path, roots);
	return {
		readFile: (path: string): Result<string, IoError> => fromMachine(path) ? machine.readFile(path) : system.readFile(path),
		readFileBytes: (path: string): Result<Buffer, IoError> => fromMachine(path) ? machine.readFileBytes(path) : system.readFileBytes(path),
		writeFile: system.writeFile,
		appendFile: system.appendFile,
		exists: (path: string): boolean => fromMachine(path) ? machine.exists(path) : system.exists(path),
		isFile: (path: string): boolean => fromMachine(path) ? machine.isFile(path) : system.isFile(path),
		isDir: (path: string): boolean => fromMachine(path) ? machine.isDir(path) : system.isDir(path),
		isExecutable: (path: string): boolean => fromMachine(path) ? machine.isExecutable(path) : system.isExecutable(path),
		readDir: (path: string): string[] => fromMachine(path) ? machine.readDir(path) : system.readDir(path),
		realpath: (path: string): string => fromMachine(path) ? machine.realpath(path) : system.realpath(path),
		ensureDir: system.ensureDir,
		mkdir: system.mkdir,
		remove: system.remove,
		removeAll: system.removeAll,
		rmdir: system.rmdir,
		rename: system.rename,
		symlink: system.symlink,
		copyFile: system.copyFile,
		fileSize: (path: string): number => fromMachine(path) ? machine.fileSize(path) : system.fileSize(path),
		modifiedTime: (path: string): number => fromMachine(path) ? machine.modifiedTime(path) : system.modifiedTime(path),
		changedTime: (path: string): number => fromMachine(path) ? machine.changedTime(path) : system.changedTime(path),
		changeStamp: (path: string): string => fromMachine(path) ? machine.changeStamp(path) : system.changeStamp(path),
		getEnv: system.getEnv,
		cwd: system.cwd,
		execPath: system.execPath,
	};
}

export function createInterpreter(runtimeRoot: string, searchPaths: string[] = [], system: System | null = null): Result<Interpreter, string> {
	if (!exists(join(runtimeRoot, "std/core/system/index.ms"))) {
		return Result.err(`no MetaScript std under ${runtimeRoot}: expected ${runtimeRoot}/std/core/system/index.ms`);
	}
	const opts = newCliOptions();
	for (const dir of searchPaths) {
		const present = system != null ? system.isDir(dir) : exists(dir);
		if (!present) return Result.err(`no search path ${dir}: the directory does not exist`);
		opts.resolve.searchPaths.push(dir);
	}
	setHostRuntimeDir(runtimeRoot);
	const sandbox = system != null ? readingRuntimeFromMachine(system, [runtimeRoot, resolveRuntimeDir()]) : null;
	return Result.ok({ opts, session: createBuildSession(true), run: null, output: [], system: sandbox });
}

function errorAt(file: string, message: string): Diagnostic {
	return { file, line: 0, column: 0, message, severity: ErrorSeverity.Error };
}

export function evalModule(interp: Interpreter, path: string): Result<Evaluation, Diagnostic[]> {
	const outer = activeSystem();
	setActiveSystem(interp.system);
	try {
		return evaluate(interp, path);
	} finally {
		setActiveSystem(outer);
	}
}

function evaluate(interp: Interpreter, path: string): Result<Evaluation, Diagnostic[]> {
	const diagnostics: Diagnostic[] = [];
	setDiagnosticHook((file: string, e: ModuleError): void => {
		diagnostics.push({ file, line: e.line, column: e.column, message: e.message, severity: e.severity });
	});
	setRecoverableBuild(true);
	if (!holdsBuildState(interp.session)) interp.session = createBuildSession(true);
	let compiled: RaiserModule | null = null;
	try {
		compiled = compileRaiser(path, interp.opts, interp.session, true);
	} catch (e) {
		if (e.message != BUILD_STOPPED) {
			diagnostics.push(errorAt(path, `internal: ${e.message}`));
			interp.session = createBuildSession(true);
		}
	}
	setRecoverableBuild(false);
	setDiagnosticHook(null);
	if (compiled == null) return Result.err(diagnostics);

	const lines: string[] = [];
	const ctx = runRaiser(compiled, [path], (text: string): void => { lines.push(text); }, true, "", true);
	if (ctx.lastError != "") return Result.err([errorAt(path, `raiser runtime error: ${ctx.lastError}`)]);
	if (ctx.orphanFailures.length > 0) {
		const failures: Diagnostic[] = [];
		for (const msg of ctx.orphanFailures) failures.push(errorAt(path, `unhandled rejection: ${msg}`));
		return Result.err(failures);
	}
	let output = "";
	for (const line of lines) output = output + line + "\n";
	const exitCode = ctx.lastResult.kind == RaiserValueKind.Int ? ctx.lastResult.intVal as int32 : 0;
	interp.run = ctx;
	interp.output = lines;
	return Result.ok({ output, exitCode, warnings: diagnostics });
}

export function selectRoutine(interp: Interpreter, name: string): Result<Routine, string> {
	const run = interp.run;
	if (run == null) return Result.err(`no evaluated module to select '${name}' from: no evalModule has succeeded`);
	let found: Routine | null = null;
	for (const exported of run.mod.exports) {
		if (exported.name != name || exported.global >= 0) continue;
		if (found != null) return Result.err(`'${name}' is overloaded in the evaluated module; a host selects only a unique routine`);
		found = { name, mod: run.mod, funcIdx: exported.funcIdx, arity: exported.arity };
	}
	if (found == null) return Result.err(`the evaluated module exports no function '${name}'`);
	return Result.ok(found);
}

function sinkParams(routine: Routine): boolean[] {
	for (const exported of routine.mod.exports) {
		if (exported.funcIdx == routine.funcIdx) return exported.sinks;
	}
	throw new Error(`internal: '${routine.name}' is not an export of its module`);
}

export function callRoutine(interp: Interpreter, routine: Routine, args: RaiserHostValue[]): Result<RaiserHostValue, string> {
	const outer = activeSystem();
	setActiveSystem(interp.system);
	try {
		return invoke(interp, routine, args);
	} finally {
		setActiveSystem(outer);
	}
}

function invoke(interp: Interpreter, routine: Routine, args: RaiserHostValue[]): Result<RaiserHostValue, string> {
	const run = interp.run;
	if (run == null || run.mod != routine.mod) return Result.err(`'${routine.name}' was selected before the last evalModule; select it again`);
	if (args.length != routine.arity) return Result.err(`'${routine.name}' takes ${routine.arity} argument(s), got ${args.length}`);
	const vm = run.vm!;
	const passed: RaiserValue[] = [];
	for (const arg of args) passed.push(copyToVm(vm.arrayHeap, vm.objectHeap, arg));
	const result = vmCallHeld(vm, routine.funcIdx, passed, sinkParams(routine));
	if (vm.error != "") {
		const failure = `raiser runtime error in '${routine.name}': ${vm.error}\n${vmDumpStack(vm)}`;
		vmReleaseRun(vm);
		return Result.err(failure);
	}
	const copied = copyToHost(vm.arrayHeap, vm.objectHeap, result);
	vmReleaseRun(vm);
	return Result.ok(copied);
}

// A host call returns once its routine and the promise jobs it queued ran; a timer it armed waits for the host.
// The host's loop runs one turn per wake: the timers already due fire, with the jobs they queue, nothing sleeps,
// and the result is the milliseconds until the next timer is due (-1 when none is armed), for the host's own wait.
export function runDueTimers(interp: Interpreter): Result<number, string> {
	const run = interp.run;
	if (run == null || run.vm == null) return Result.err("no evaluated module to run timers in: no evalModule has succeeded");
	const vm = run.vm!;
	const outer = activeSystem();
	setActiveSystem(interp.system);
	try {
		const next = vmRunDueTimers(vm);
		if (vm.error != "") {
			const failure = `raiser runtime error in a timer: ${vm.error}\n${vmDumpStack(vm)}`;
			vmReleaseRun(vm);
			return Result.err(failure);
		}
		vmReleaseRun(vm);
		return Result.ok(next);
	} finally {
		setActiveSystem(outer);
	}
}

export function nextTimerDelayMs(interp: Interpreter): number {
	const run = interp.run;
	return run == null || run.vm == null ? -1 : vmNextTimerDelayMs(run.vm!);
}

export function implementRoutine(nativeName: string, impl: RaiserHostFn): void {
	registerHostFn(nativeName, (args: RaiserValue[]): RaiserValue => {
		try {
			return impl(args);
		} catch (e) {
			raiseFromHost(e.message, false);
			return boxVoid();
		}
	});
	routeHostFnThroughSystem(nativeName);
}

export function implementRoutineInPlace(nativeName: string, impl: RaiserInPlaceHostFn): void {
	registerInPlaceHostFn(nativeName, (call: RaiserVM): void => {
		const outerObjects = activeHostObjectHeap();
		const outerArrays = activeHostArrayHeap();
		setActiveHostHeaps(call.objectHeap, call.arrayHeap);
		try {
			impl(call);
		} catch (e) {
			raiseFromHost(e.message, false);
		}
		setActiveHostHeaps(outerObjects, outerArrays);
	});
	routeHostFnThroughSystem(nativeName);
}

export function unboxValue(v: RaiserValue): RaiserHostValue {
	const arrays = activeHostArrayHeap();
	const objects = activeHostObjectHeap();
	if (arrays == null || objects == null) throw new Error("unboxValue reads an argument of a host routine, and no script has called one");
	return copyToHost(arrays, objects, v);
}

export function boxValue(v: RaiserHostValue): RaiserValue {
	const arrays = activeHostArrayHeap();
	const objects = activeHostObjectHeap();
	if (arrays == null || objects == null) throw new Error("boxValue builds the result of a host routine, and no script has called one");
	return copyToVm(arrays, objects, v);
}

function scratchDir(): string {
	const dir = `out/test/embed.${performance.now()}`;
	ensureDir(dir);
	return dir;
}

function testInterpreter(searchPaths: string[] = []): Interpreter {
	const created = createInterpreter(resolveRuntimeDir(), searchPaths);
	if (!created.ok) throw new Error(created.error);
	return created.value;
}

function outputOf(interp: Interpreter, path: string): string {
	const r = evalModule(interp, path);
	if (r.ok) return r.value.output;
	return `error: ${r.error[0].message}`;
}

test "createInterpreter refuses a root without std" {
	const dir = scratchDir();
	const created = createInterpreter(dir);
	assert !created.ok;
	if (!created.ok) assert created.error.includes("no MetaScript std");
	removeAll(dir);
}

test "evalModule runs a module that imports a sibling and std" {
	const dir = scratchDir();
	writeFile(`${dir}/config.ms`, `export const config = { fontFamily: ["OperatorMonoLig Nerd Font Mono"], size: 14 };\n`);
	writeFile(`${dir}/main.ms`, `import { config } from "./config";\nconsole.log(JSON.stringify(config));\n`);
	assert outputOf(testInterpreter(), `${dir}/main.ms`) == `{"fontFamily":["OperatorMonoLig Nerd Font Mono"],"size":14}\n`;
	removeAll(dir);
}

test "evalModule takes a value a macro computed" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `import { Node, NodeKind } from "std/meta";\n`
		+ `macro sameTag(): Node { const a: string[] = ["m", "n"]; return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: a[0] + a[1] == "mn" }; }\n`
		+ `console.log(\`\${sameTag()}\`);\n`);
	assert outputOf(testInterpreter(), `${dir}/main.ms`) == "true\n";
	removeAll(dir);
}

test "evalModule returns a type error as a diagnostic and the host keeps running" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `const size: int32 = "big";\nconsole.log(size);\n`);
	const interp = testInterpreter();
	const r = evalModule(interp, `${dir}/main.ms`);
	assert !r.ok;
	if (!r.ok) {
		assert r.error.length == 1;
		assert r.error[0].file.endsWith("/main.ms");
		assert r.error[0].line == 1;
		assert r.error[0].severity == ErrorSeverity.Error;
		assert r.error[0].message.includes("not assignable");
	}
	writeFile(`${dir}/main.ms`, `const size: int32 = 3;\nconsole.log(size);\n`);
	assert outputOf(interp, `${dir}/main.ms`) == "3\n";
	removeAll(dir);
}

test "evalModule reloads an edited import in one interpreter" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `import { size } from "./config";\nconsole.log(size * 2);\n`);
	const interp = testInterpreter();
	writeFile(`${dir}/config.ms`, `export const size: int32 = 7;\n`);
	assert outputOf(interp, `${dir}/main.ms`) == "14\n";
	writeFile(`${dir}/config.ms`, `export const size: int32 = 21;\n`);
	assert outputOf(interp, `${dir}/main.ms`) == "42\n";
	removeAll(dir);
}

test "evalModule reloads an edited macro in an imported module" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `import { flag } from "./flags";\nconsole.log(\`\${flag()}\`);\n`);
	const interp = testInterpreter();
	writeFile(`${dir}/flags.ms`, `import { Node, NodeKind } from "std/meta";\n`
		+ `export macro flag(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: 1 + 1 == 2 }; }\n`);
	assert outputOf(interp, `${dir}/main.ms`) == "true\n";
	writeFile(`${dir}/flags.ms`, `import { Node, NodeKind } from "std/meta";\n`
		+ `export macro flag(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: 1 + 1 == 3 }; }\n`);
	assert outputOf(interp, `${dir}/main.ms`) == "false\n";
	removeAll(dir);
}

test "evalModule returns a runtime error and an exit code without leaving the host" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `const xs: int32[] = [1];\nconsole.log(xs[5]);\n`);
	const interp = testInterpreter();
	const thrown = evalModule(interp, `${dir}/main.ms`);
	assert !thrown.ok;
	if (!thrown.ok) assert thrown.error[0].message.startsWith("raiser runtime error");
	writeFile(`${dir}/main.ms`, `console.log("bye");\nprocess.exit(3);\n`);
	const exited = evalModule(interp, `${dir}/main.ms`);
	assert exited.ok;
	if (exited.ok) {
		assert exited.value.output == "bye\n";
		assert exited.value.exitCode == 3;
	}
	removeAll(dir);
}

function writePackageShape(dir: string, fontField: string): void {
	ensureDir(`${dir}/pkgs/haro`);
	ensureDir(`${dir}/cfg`);
	ensureDir(`${dir}/run`);
	writeFile(`${dir}/pkgs/haro/index.ms`, `export interface HaroConfig {\n\tfontFamily?: string[];\n\tfontSize?: number;\n}\n`);
	writeFile(`${dir}/pkgs/theme.ms`, `export const accent = "teal";\n`);
	writeFile(`${dir}/cfg/config.ms`, `import { HaroConfig } from "haro";\nexport const config: HaroConfig = { fontFamily: ["Menlo"], ${fontField}: 13 };\n`);
	writeFile(`${dir}/run/main.ms`, `import { config } from "../cfg/config";\nimport { accent } from "theme";\nconsole.log(\`\${JSON.stringify(config)} \${accent}\`);\n`);
}

test "evalModule resolves a bare import in the entry and in a nested module through a search path the host names" {
	const dir = scratchDir();
	writePackageShape(dir, "fontSize");
	const interp = testInterpreter([`${dir}/pkgs`]);
	assert outputOf(interp, `${dir}/run/main.ms`) == `{"fontFamily":["Menlo"],"fontSize":13} teal\n`;
	removeAll(dir);
}

test "a misspelt field of a package's interface comes back with its file, line and column" {
	const dir = scratchDir();
	writePackageShape(dir, "fontSiz");
	const r = evalModule(testInterpreter([`${dir}/pkgs`]), `${dir}/run/main.ms`);
	assert !r.ok;
	if (!r.ok) {
		assert r.error.length == 1;
		assert r.error[0].file.endsWith("/cfg/config.ms");
		assert r.error[0].line == 2;
		assert r.error[0].column > 0;
		assert r.error[0].message.includes("'fontSiz' does not exist in type 'HaroConfig'");
	}
	removeAll(dir);
}

test "a package no search path holds is a diagnostic, and a search path that does not exist is refused" {
	const dir = scratchDir();
	writePackageShape(dir, "fontSize");
	const interp = testInterpreter();
	const r = evalModule(interp, `${dir}/run/main.ms`);
	assert !r.ok;
	if (!r.ok) assert r.error[0].message.includes("Cannot resolve module");
	writeFile(`${dir}/run/main.ms`, `console.log("still here");\n`);
	assert outputOf(interp, `${dir}/run/main.ms`) == "still here\n";
	const missing = createInterpreter(resolveRuntimeDir(), [`${dir}/nowhere`]);
	assert !missing.ok;
	if (!missing.ok) assert missing.error.includes("no search path");
	removeAll(dir);
}

function evaluatedInterpreter(path: string): Interpreter {
	const interp = testInterpreter();
	const r = evalModule(interp, path);
	if (!r.ok) throw new Error(r.error[0].message);
	return interp;
}

function routineOf(interp: Interpreter, name: string): Routine {
	const selected = selectRoutine(interp, name);
	if (!selected.ok) throw new Error(selected.error);
	return selected.value;
}

function intCall(interp: Interpreter, routine: Routine, args: RaiserHostValue[]): number {
	const r = callRoutine(interp, routine, args);
	if (!r.ok) throw new Error(r.error);
	return unboxInt(r.value.root);
}

test "callRoutine calls an exported function again and again over the module's state" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `let total: int32 = 100;\nexport function add(n: int32): int32 { total += n; return total; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const add = routineOf(interp, "add");
	assert intCall(interp, add, [hostValue(boxInt(2))]) == 102;
	assert intCall(interp, add, [hostValue(boxInt(3))]) == 105;
	for (let i = 0; i < 1000; i += 1) intCall(interp, add, [hostValue(boxInt(1))]);
	assert intCall(interp, add, [hostValue(boxInt(0))]) == 1105;
	removeAll(dir);
}

test "a routine that arms a timer keeps its locals after an earlier call's timer ran" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `class Box { v: int32 = 7; }\n`
		+ `export function arm(): void { setTimeout((): void => {}, 0); }\n`
		+ `export function use(): int32 { const b = new Box(); setTimeout((): void => {}, 0); return b.v; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const armed = callRoutine(interp, routineOf(interp, "arm"), []);
	if (!armed.ok) throw new Error(armed.error);
	assert intCall(interp, routineOf(interp, "use"), []) == 7;
	assert intCall(interp, routineOf(interp, "use"), []) == 7;
	removeAll(dir);
}

test "a routine that arms a timer keeps a local array after its own earlier call's timer ran" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `export function count(): int32 { const xs: int32[] = [1, 2, 3]; setTimeout((): void => {}, 0); return xs.length as int32; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const count = routineOf(interp, "count");
	assert intCall(interp, count, []) == 3;
	assert intCall(interp, count, []) == 3;
	removeAll(dir);
}

const TIMER_GUEST = `let fired: int32 = 0;\nlet micro: int32 = 0;\nlet pending: int32 = -1;\n`
	+ `export function arm(ms: int32): void { const step: int32 = 2; setTimeout((): void => { fired += step; }, ms); }\n`
	+ `export function armMicro(): void { Promise.resolve(0).then((v: int32): void => { micro += 1; }); }\n`
	+ `export function armCancelled(): void { pending = setTimeout((): void => { fired += 100; }, 30) as int32; }\n`
	+ `export function cancel(): void { clearTimeout(pending); }\n`
	+ `export function firedCount(): int32 { return fired; }\n`
	+ `export function microCount(): int32 { return micro; }\n`;

function waitMs(ms: number): void {
	const until = performance.now() + ms;
	while (performance.now() < until) {}
}

test "a host call returns before a timer it armed is due, with its promise jobs run" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, TIMER_GUEST);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const t0 = performance.now();
	const armed = callRoutine(interp, routineOf(interp, "arm"), [hostValue(boxInt(300))]);
	const took = performance.now() - t0;
	if (!armed.ok) throw new Error(armed.error);
	assert took < 150;
	assert intCall(interp, routineOf(interp, "firedCount"), []) == 0;
	const d = nextTimerDelayMs(interp);
	assert d > 100 && d <= 300;
	const m = callRoutine(interp, routineOf(interp, "armMicro"), []);
	if (!m.ok) throw new Error(m.error);
	assert intCall(interp, routineOf(interp, "microCount"), []) == 1;
	removeAll(dir);
}

test "a host turn fires a due timer once, with the closure it captured, across later calls" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, TIMER_GUEST);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const armed = callRoutine(interp, routineOf(interp, "arm"), [hostValue(boxInt(20))]);
	if (!armed.ok) throw new Error(armed.error);
	assert intCall(interp, routineOf(interp, "firedCount"), []) == 0;
	const early = runDueTimers(interp);
	if (!early.ok) throw new Error(early.error);
	assert early.value >= 0;
	assert intCall(interp, routineOf(interp, "firedCount"), []) == 0;
	waitMs(30);
	const turn = runDueTimers(interp);
	if (!turn.ok) throw new Error(turn.error);
	assert turn.value == -1;
	assert intCall(interp, routineOf(interp, "firedCount"), []) == 2;
	const again = runDueTimers(interp);
	if (!again.ok) throw new Error(again.error);
	assert intCall(interp, routineOf(interp, "firedCount"), []) == 2;
	removeAll(dir);
}

test "a later host call cancels a pending timer an earlier call armed" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, TIMER_GUEST);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const armed = callRoutine(interp, routineOf(interp, "armCancelled"), []);
	if (!armed.ok) throw new Error(armed.error);
	const cancelled = callRoutine(interp, routineOf(interp, "cancel"), []);
	if (!cancelled.ok) throw new Error(cancelled.error);
	assert nextTimerDelayMs(interp) == -1;
	waitMs(40);
	const turn = runDueTimers(interp);
	if (!turn.ok) throw new Error(turn.error);
	assert intCall(interp, routineOf(interp, "firedCount"), []) == 0;
	removeAll(dir);
}

test "callRoutine passes floats and strings and returns them" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `export function step(x: number, dt: number): number { return x + 2.5 * dt; }\n`
		+ `export function greet(who: string): string { return \`hi \${who}\`; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const step = callRoutine(interp, routineOf(interp, "step"), [hostValue(boxFloat(1.0)), hostValue(boxFloat(0.5))]);
	assert step.ok;
	if (step.ok) assert unboxFloat(step.value.root) == 2.25;
	const greet = callRoutine(interp, routineOf(interp, "greet"), [hostString("haro")]);
	assert greet.ok;
	if (greet.ok) assert greet.value.text() == "hi haro";
	removeAll(dir);
}

test "callRoutine returns the JSON of a typed config that spreads an imported theme" {
	const dir = scratchDir();
	writeFile(`${dir}/theme.ms`, `export interface Config { fontSize: int32; background: string; }\nexport const night: Config = { fontSize: 11, background: "#16161e" };\n`);
	writeFile(`${dir}/config.ms`, `import { Config, night } from "./theme";\nexport const config: Config = { ...night, fontSize: 13 };\n`);
	writeFile(`${dir}/main.ms`, `import { config } from "./config";\nexport function configJson(): string { return JSON.stringify(config); }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const got = callRoutine(interp, routineOf(interp, "configJson"), []);
	assert got.ok;
	if (got.ok) assert got.value.text() == `{"fontSize":13,"background":"#16161e"}`, got.value.text();
	removeAll(dir);
}

test "selectRoutine finds only an exported function of the evaluated module" {
	const dir = scratchDir();
	writeFile(`${dir}/lib.ms`, `export function fromLib(): int32 { return 1; }\n`);
	writeFile(`${dir}/main.ms`, `import { fromLib } from "./lib";\nfunction hidden(): int32 { return fromLib(); }\nexport function shown(): int32 { return hidden(); }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	assert intCall(interp, routineOf(interp, "shown"), []) == 1;
	const hidden = selectRoutine(interp, "hidden");
	assert !hidden.ok;
	if (!hidden.ok) assert hidden.error.includes("exports no function 'hidden'");
	assert !selectRoutine(interp, "fromLib").ok;
	removeAll(dir);
}

test "selectRoutine finds a function the evaluated module re-exports" {
	const dir = scratchDir();
	writeFile(`${dir}/user.ms`, `export function onKey(code: int32): int32 { return code + 1; }\n`);
	writeFile(`${dir}/named.ms`, `export { onKey } from "./user";\nexport function own(): int32 { return 7; }\n`);
	writeFile(`${dir}/star.ms`, `export * from "./user";\n`);
	writeFile(`${dir}/renamed.ms`, `export { onKey as press } from "./user";\n`);
	writeFile(`${dir}/chain.ms`, `export * from "./star";\n`);
	for (const entry of ["named", "star", "chain"]) {
		const interp = evaluatedInterpreter(`${dir}/${entry}.ms`);
		assert intCall(interp, routineOf(interp, "onKey"), [hostValue(boxInt(4))]) == 5, entry;
	}
	const renamed = evaluatedInterpreter(`${dir}/renamed.ms`);
	assert intCall(renamed, routineOf(renamed, "press"), [hostValue(boxInt(1))]) == 2;
	assert !selectRoutine(renamed, "onKey").ok;
	removeAll(dir);
}

test "selectRoutine refuses an overloaded name" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `export function f(a: int32): int32 { return a; }\nexport function f(a: string): string { return a; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const f = selectRoutine(interp, "f");
	assert !f.ok;
	if (!f.ok) assert f.error.includes("'f' is overloaded");
	removeAll(dir);
}

test "callRoutine refuses a wrong arity and a routine selected before a reload" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `export function twice(n: int32): int32 { return n * 2; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const twice = routineOf(interp, "twice");
	const wrong = callRoutine(interp, twice, []);
	assert !wrong.ok;
	if (!wrong.ok) assert wrong.error.includes("takes 1 argument(s), got 0");
	writeFile(`${dir}/main.ms`, `export function twice(n: int32): int32 { return n * 3; }\n`);
	assert evalModule(interp, `${dir}/main.ms`).ok;
	const stale = callRoutine(interp, twice, [hostValue(boxInt(5))]);
	assert !stale.ok;
	if (!stale.ok) assert stale.error.includes("select it again");
	assert intCall(interp, routineOf(interp, "twice"), [hostValue(boxInt(5))]) == 15;
	removeAll(dir);
}

test "a failed evalModule keeps the running program and its state" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `let total: int32 = 100;\nexport function add(n: int32): int32 { total += n; return total; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const add = routineOf(interp, "add");
	assert intCall(interp, add, [hostValue(boxInt(1))]) == 101;
	writeFile(`${dir}/main.ms`, `let total: int32 = 100;\nexport function add(n: int32): int32 { total += n; return "typo"; }\n`);
	assert !evalModule(interp, `${dir}/main.ms`).ok;
	assert intCall(interp, add, [hostValue(boxInt(1))]) == 102;
	writeFile(`${dir}/main.ms`, `throw new Error("init refused");\nexport function add(n: int32): int32 { return n; }\n`);
	const thrown = evalModule(interp, `${dir}/main.ms`);
	assert !thrown.ok;
	if (!thrown.ok) assert thrown.error[0].message.includes("init refused");
	assert intCall(interp, add, [hostValue(boxInt(1))]) == 103;
	writeFile(`${dir}/main.ms`, `let total: int32 = 0;\nexport function add(n: int32): int32 { total += n * 10; return total; }\n`);
	assert evalModule(interp, `${dir}/main.ms`).ok;
	const stale = callRoutine(interp, add, [hostValue(boxInt(1))]);
	assert !stale.ok;
	assert intCall(interp, routineOf(interp, "add"), [hostValue(boxInt(1))]) == 10;
	removeAll(dir);
}

test "callRoutine returns a runtime error of the routine and the host keeps calling" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `const xs: int32[] = [1, 2];\nexport function at(i: int32): int32 { return xs[i]; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const at = routineOf(interp, "at");
	const bad = callRoutine(interp, at, [hostValue(boxInt(7))]);
	assert !bad.ok;
	if (!bad.ok) assert bad.error.startsWith("raiser runtime error in 'at'");
	assert intCall(interp, at, [hostValue(boxInt(1))]) == 2;
	removeAll(dir);
}

test "a script calls a function the host implements" {
	const seen: number[] = [];
	implementRoutine("embedTest.record", (args: RaiserValue[]): RaiserValue => {
		seen.push(unboxInt(args[0]));
		return boxVoid();
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `extern function record(n: int32): void from "embedTest.record";\nrecord(1);\nexport function tick(n: int32): void { record(n * 10); }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const r = callRoutine(interp, routineOf(interp, "tick"), [hostValue(boxInt(4))]);
	assert r.ok;
	assert seen.length == 2;
	assert seen[0] == 1;
	assert seen[1] == 40;
	removeAll(dir);
}

test "a host call, a ref argument and a host call nested in one audit no heap, keep the module's state and leave its heap as they found it" {
	const nested: Interpreter[] = [];
	implementRoutine("embedTest.reenter", (args: RaiserValue[]): RaiserValue => {
		const inner = callRoutine(nested[0], routineOf(nested[0], "size"), [hostString(unboxValue(args[0]).text())]);
		if (!inner.ok) throw new Error(inner.error);
		return boxInt(unboxInt(inner.value.root) * 10);
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `interface Cell { n: int32; tag: string; }\n`
		+ `const cells: Cell[] = [];\n`
		+ `for (let i: int32 = 0; i < 1000; i += 1) cells.push({ n: i, tag: \`cell \${i}\` });\n`
		+ `let calls: int32 = 0;\n`
		+ `export function noop(): void {}\n`
		+ `export function count(): int32 { calls += 1; return calls; }\n`
		+ `export function size(s: string): int32 { return s.length; }\n`
		+ `extern function reenter(s: string): int32 from "embedTest.reenter";\n`
		+ `export function outer(s: string): int32 { return reenter(s) + cells.length; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	nested.push(interp);
	const vm = interp.run!.vm!;
	const audits = ledgerAudits();
	let objects = 0;
	let cells = 0;
	for (let round = 0; round < 100; round += 1) {
		routineValue(interp, "noop", []);
		assert unboxInt(routineValue(interp, "count", []).root) == round + 1;
		assert unboxInt(routineValue(interp, "size", [hostString(`round ${round}`)]).root) == `round ${round}`.length;
		assert unboxInt(routineValue(interp, "outer", [hostString("hey")]).root) == 1030;
		if (round == 0) {
			objects = vm.objectHeap.objects.length;
			cells = liveCellBlocks(vm.arrayHeap.mem).length;
		}
	}
	assert ledgerAudits() == audits, `${ledgerAudits() - audits} heap audits ran in 400 host calls`;
	assert vm.objectHeap.objects.length == objects;
	assert liveCellBlocks(vm.arrayHeap.mem).length == cells;
	removeAll(dir);
}

test "a host routine that throws raises into the script's catch" {
	implementRoutine("embedTest.fail", (args: RaiserValue[]): RaiserValue => {
		throw new Error("host refused");
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `extern function fail(): void from "embedTest.fail";\nexport function guarded(): string { try { fail(); } catch (e) { return "caught: " + e.message; } return "missed"; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const r = callRoutine(interp, routineOf(interp, "guarded"), []);
	assert r.ok, r.ok ? "" : r.error;
	if (r.ok) assert r.value.text() == "caught: host refused";
	removeAll(dir);
}

test "an in-place host routine reads int, float, bool and string arguments where the VM keeps them and writes its result there" {
	implementRoutineInPlace("embedTest.mix", (call: RaiserVM): void => {
		hostReturnString(call, `${hostArgInt(call, 0)} ${hostArgFloat(call, 1)} ${hostArgBool(call, 2)} ${hostArgString(call, 3)} ${hostArgCount(call)}`);
	});
	implementRoutineInPlace("embedTest.scale", (call: RaiserVM): void => {
		hostReturnFloat(call, hostArgFloat(call, 0) * (hostArgInt(call, 1) as number));
	});
	implementRoutineInPlace("embedTest.odd", (call: RaiserVM): void => {
		hostReturnBool(call, hostArgInt(call, 0) % 2 == 1);
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `extern function mix(n: int64, x: number, b: boolean, s: string): string from "embedTest.mix";\n`
		+ `extern function scale(x: number, k: int32): number from "embedTest.scale";\n`
		+ `extern function odd(n: int32): boolean from "embedTest.odd";\n`
		+ `export function run(n: int32): string { return mix(n * 2, scale(1.5, n), odd(n), "s" + n.toString()); }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	assert routineValue(interp, "run", [hostValue(boxInt(3))]).text() == "6 4.5 true s3 4";
	assert routineValue(interp, "run", [hostValue(boxInt(4))]).text() == "8 6 false s4 4";
	removeAll(dir);
}

test "an in-place host routine that throws raises into the script's catch, and the next call runs" {
	implementRoutineInPlace("embedTest.failInPlace", (call: RaiserVM): void => {
		if (hostArgInt(call, 0) < 0) throw new Error(`in-place refused ${hostArgInt(call, 0)}`);
		hostReturnInt(call, hostArgInt(call, 0) + 1);
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `extern function step(n: int32): int32 from "embedTest.failInPlace";\n`
		+ `export function guarded(n: int32): string { try { return "got " + step(n).toString(); } catch (e) { return "caught: " + e.message; } }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	assert routineValue(interp, "guarded", [hostValue(boxInt(-2))]).text() == "caught: in-place refused -2";
	assert routineValue(interp, "guarded", [hostValue(boxInt(6))]).text() == "got 7";
	removeAll(dir);
}

test "a host routine's throw, uncaught two script frames deep, comes back as Result.err and the host keeps calling" {
	implementRoutine("embedTest.failDeep", (args: RaiserValue[]): RaiserValue => {
		throw new Error("deep refusal");
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `extern function failDeep(): void from "embedTest.failDeep";\nfunction inner(): void { failDeep(); }\nfunction outer(): void { inner(); }\nexport function run(): void { outer(); }\nexport function ok(): int32 { return 7; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const bad = callRoutine(interp, routineOf(interp, "run"), []);
	assert !bad.ok;
	if (!bad.ok) assert bad.error.includes("deep refusal"), bad.error;
	assert intCall(interp, routineOf(interp, "ok"), []) == 7;
	removeAll(dir);
}

test "an uncaught throw of the script, of a host routine or of a module's error leaves the heap as it found it" {
	implementRoutine("embedTest.refuse", (args: RaiserValue[]): RaiserValue => {
		throw new Error("host refusal");
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `extern function refuse(): void from "embedTest.refuse";\n`
		+ `const shared = new Error("shared refusal");\n`
		+ `export function hostThrow(): void { refuse(); }\n`
		+ `export function scriptThrow(): void { throw new Error("script refusal"); }\n`
		+ `export function sharedThrow(): void { throw shared; }\n`
		+ `export function sharedMessage(): string { return shared.message; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const vm = interp.run!.vm!;
	let objects = 0;
	let cells = 0;
	for (let round = 0; round < 200; round += 1) {
		for (const name of ["hostThrow", "scriptThrow", "sharedThrow"]) {
			const r = callRoutine(interp, routineOf(interp, name), []);
			assert !r.ok, name;
			if (!r.ok) assert r.error.includes("refusal"), r.error;
		}
		if (round == 0) {
			objects = vm.objectHeap.objects.length;
			cells = liveCellBlocks(vm.arrayHeap.mem).length;
		}
	}
	assert vm.objectHeap.objects.length == objects;
	assert liveCellBlocks(vm.arrayHeap.mem).length == cells;
	assert routineValue(interp, "sharedMessage", []).text() == "shared refusal";
	removeAll(dir);
}

test "a routine that keeps a struct the host passed holds it after the call, and the host's copy is released" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `export interface Key { code: string; mods: int32; }\n`
		+ `let kept: Key = { code: "none", mods: 0 };\n`
		+ `export function keep(e: Key): void { kept = e; }\n`
		+ `export function keptCode(): string { return kept.code; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	routineValue(interp, "keep", [keyEvent("KeyA", 2)]);
	routineValue(interp, "keep", [keyEvent("KeyB", 0)]);
	assert routineValue(interp, "keptCode", []).text() == "KeyB";
	const vm = interp.run!.vm!;
	const objects = vm.objectHeap.objects.length;
	const cells = liveCellBlocks(vm.arrayHeap.mem).length;
	for (let i = 0; i < 500; i += 1) routineValue(interp, "keep", [keyEvent(`Key${i}`, i)]);
	assert routineValue(interp, "keptCode", []).text() == "Key499";
	assert vm.objectHeap.objects.length == objects;
	assert liveCellBlocks(vm.arrayHeap.mem).length == cells;
	removeAll(dir);
}

function routineValue(interp: Interpreter, name: string, args: RaiserHostValue[]): RaiserHostValue {
	const r = callRoutine(interp, routineOf(interp, name), args);
	if (!r.ok) throw new Error(r.error);
	return r.value;
}

function keyEvent(code: string, mods: number): RaiserHostValue {
	return hostObject(["code", "mods"], [hostString(code), hostValue(boxInt(mods))]);
}

const HARO_SCRIPT = `export interface Bind { keys: string; text: string; }\n`
	+ `export interface HaroConfig { fontFamily: string[]; fontSize?: number; mode?: "alt" | "~alt"; binds: Bind[]; }\n`
	+ `export const config: HaroConfig = { fontFamily: ["Operator Mono", "Menlo"], mode: "alt", `
	+ `binds: [{ keys: "ctrl+a", text: "home" }, { keys: "ctrl+e", text: "end" }] };\n`
	+ `export function current(): HaroConfig { return config; }\n`
	+ `export function onKey(e: { code: string; mods: int32 }): { handled: boolean; send: string } {\n`
	+ `\treturn { handled: e.mods == 2, send: \`\${e.code}:\${e.mods}\` };\n}\n`;

test "callRoutine returns a struct whose array of structs, absent optional and literal-union field the host reads" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, HARO_SCRIPT);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const config = routineValue(interp, "current", []);
	const fonts = config.field("fontFamily");
	assert fonts.length() == 2;
	assert fonts.at(1).text() == "Menlo";
	assert config.field("fontSize").root.kind == RaiserValueKind.Nil;
	assert config.field("mode").text() == "alt";
	const binds = config.field("binds");
	assert binds.length() == 2;
	assert binds.at(1).field("keys").text() == "ctrl+e";
	assert binds.at(1).field("text").text() == "end";
	removeAll(dir);
}

test "callRoutine passes a struct the host built and the struct it returns outlives the next call" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, HARO_SCRIPT);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const key = keyEvent("KeyA", 2);
	const first = routineValue(interp, "onKey", [key]);
	assert unboxBool(first.field("handled").root);
	assert first.field("send").text() == "KeyA:2";
	const second = routineValue(interp, "onKey", [keyEvent("KeyB", 0)]);
	assert !unboxBool(second.field("handled").root);
	assert first.field("send").text() == "KeyA:2";
	assert routineValue(interp, "onKey", [key]).field("send").text() == "KeyA:2";
	const vm = interp.run!.vm!;
	const objects = vm.objectHeap.objects.length;
	const arrays = liveCellBlocks(vm.arrayHeap.mem).length;
	for (let i = 0; i < 2000; i += 1) {
		routineValue(interp, "onKey", [key]);
		routineValue(interp, "current", []);
	}
	assert vm.objectHeap.objects.length == objects;
	assert liveCellBlocks(vm.arrayHeap.mem).length == arrays;
	removeAll(dir);
}

function memorySystem(files: Map<string, string>, home: string): System {
	const holds = (path: string): boolean => files.has(path);
	const holdsDir = (path: string): boolean => {
		for (const key of files.keys()) if (key.startsWith(`${path}/`)) return true;
		return false;
	};
	const refused = (path: string): Result<void, IoError> => Result.err(notFound(path));
	return {
		readFile: (path: string): Result<string, IoError> => holds(path) ? Result.ok(files.get(path)!) : Result.err(notFound(path)),
		readFileBytes: (path: string): Result<Buffer, IoError> => Result.err(notFound(path)),
		writeFile: (path: string, content: string): Result<void, IoError> => { files.set(path, content); return Result.ok(null); },
		appendFile: (path: string, content: string): Result<void, IoError> => refused(path),
		exists: (path: string): boolean => holds(path) || holdsDir(path),
		isFile: holds,
		isDir: holdsDir,
		isExecutable: (path: string): boolean => false,
		readDir: (path: string): string[] => [],
		realpath: (path: string): string => holds(path) || holdsDir(path) ? path : "",
		ensureDir: refused,
		mkdir: refused,
		remove: refused,
		removeAll: refused,
		rmdir: refused,
		rename: (oldPath: string, newPath: string): Result<void, IoError> => refused(oldPath),
		symlink: (target: string, path: string): Result<void, IoError> => refused(path),
		copyFile: (src: string, dst: string): Result<void, IoError> => refused(src),
		fileSize: (path: string): number => holds(path) ? files.get(path)!.length : -1,
		modifiedTime: (path: string): number => 0,
		changedTime: (path: string): number => 0,
		changeStamp: (path: string): string => holds(path) ? files.get(path)! : "",
		getEnv: (name: string): string => name == "HOME" ? home : "",
		cwd: (): string => "/virtual/app",
		execPath: (): string => "/virtual/bin/editor",
	};
}

function stringCall(interp: Interpreter, name: string): string {
	const r = callRoutine(interp, routineOf(interp, name), []);
	if (!r.ok) return `error: ${r.error}`;
	return r.value.text();
}

const VIRTUAL_MAIN = `import { twice } from "./lib";
import { readFile, readLines } from "std/fs";
import { env } from "std/process";
const atCompile = @comptime { return readFile("/virtual/app/data.txt").ok ? "compile-read" : "compile-none"; };
export function note(): string { const r = readFile("/virtual/app/data.txt"); return r.ok ? r.value : "missing"; }
export function home(): string { return env.get("HOME"); }
export function seen(): string { return atCompile; }
export function doubled(n: int32): int32 { return twice(n); }
export function lines(): string { const r = readLines("/virtual/app/data.txt"); return r.ok ? "read lines" : "no lines"; }
`;

test "an interpreter given a system compiles an import only that system holds, and its program and macros read that system" {
	const files = new Map<string, string>();
	files.set("/virtual/app/main.ms", VIRTUAL_MAIN);
	files.set("/virtual/app/lib.ms", `export function twice(n: int32): int32 { return n * 2; }\n`);
	files.set("/virtual/app/data.txt", "from the embedder");
	const created = createInterpreter(resolveRuntimeDir(), [], memorySystem(files, "/home/guest"));
	if (!created.ok) throw new Error(created.error);
	const interp = created.value;
	const r = evalModule(interp, "/virtual/app/main.ms");
	assert r.ok, r.ok ? "" : r.error[0].message;
	assert stringCall(interp, "note") == "from the embedder";
	assert stringCall(interp, "home") == "/home/guest";
	assert stringCall(interp, "seen") == "compile-read";
	assert intCall(interp, routineOf(interp, "doubled"), [hostValue(boxInt(21))]) == 42;
	const refused = stringCall(interp, "lines");
	assert refused.includes("a sandboxed interpreter cannot call host function 'std/fs.readLines'"), refused;
	files.set("/virtual/app/lib.ms", `export function twice(n: int32): int32 { return n * 3; }\n`);
	assert evalModule(interp, "/virtual/app/main.ms").ok;
	assert intCall(interp, routineOf(interp, "doubled"), [hostValue(boxInt(21))]) == 63;
}

test "a sandboxed guest calls the routines its embedder implements" {
	implementRoutine("embedTest.sandboxPing", (args: RaiserValue[]): RaiserValue => boxInt(unboxInt(args[0]) + 1));
	implementRoutineInPlace("embedTest.sandboxPong", (vm: RaiserVM): void => { hostReturnInt(vm, hostArgInt(vm, 0) * 2); });
	const files = new Map<string, string>();
	files.set("/virtual/app/main.ms", `extern function ping(n: int32): int32 from "embedTest.sandboxPing";\n`
		+ `extern function pong(n: int32): int32 from "embedTest.sandboxPong";\n`
		+ `export function both(n: int32): int32 { return ping(n) + pong(n); }\n`);
	const created = createInterpreter(resolveRuntimeDir(), [], memorySystem(files, "/home/guest"));
	if (!created.ok) throw new Error(created.error);
	const interp = created.value;
	const r = evalModule(interp, "/virtual/app/main.ms");
	assert r.ok, r.ok ? "" : r.error[0].message;
	assert intCall(interp, routineOf(interp, "both"), [hostValue(boxInt(20))]) == 61;
}

test "an interpreter created without a system reads the real disk beside one given a system" {
	const files = new Map<string, string>();
	files.set("/virtual/app/main.ms", VIRTUAL_MAIN);
	files.set("/virtual/app/lib.ms", `export function twice(n: int32): int32 { return n * 2; }\n`);
	files.set("/virtual/app/data.txt", "from the embedder");
	const created = createInterpreter(resolveRuntimeDir(), [], memorySystem(files, "/home/guest"));
	if (!created.ok) throw new Error(created.error);
	const sandboxed = created.value;
	assert evalModule(sandboxed, "/virtual/app/main.ms").ok;
	const dir = scratchDir();
	writeFile(`${dir}/data.txt`, "from the disk");
	writeFile(`${dir}/main.ms`, `import { readFile } from "std/fs";\nexport function note(): string { const r = readFile("${dir}/data.txt"); return r.ok ? r.value : "missing"; }\n`
		+ `export function virtual(): string { return readFile("/virtual/app/data.txt").ok ? "leaked" : "absent"; }\n`);
	const machine = testInterpreter();
	const m = evalModule(machine, `${dir}/main.ms`);
	assert m.ok, m.ok ? "" : m.error[0].message;
	assert stringCall(machine, "note") == "from the disk";
	assert stringCall(machine, "virtual") == "absent";
	assert stringCall(sandboxed, "note") == "from the embedder";
	assert stringCall(machine, "note") == "from the disk";
	removeAll(dir);
}

test "with no host routine active a host passes a string it built, and boxString is refused" {
	setActiveHostHeaps(null, null);
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `console.log(JSON.stringify({ ran: [1] }));\n` + HARO_SCRIPT);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	assert interp.output[0] == `{"ran":[1]}`;
	assert activeHostArrayHeap() == null;
	let refused = "";
	try { boxString("KeyA"); } catch (e) { refused = e.message; }
	assert refused == "boxString and unboxString work inside a host routine; outside one, build a string argument with hostString";
	const got = routineValue(interp, "onKey", [keyEvent("KeyA", 2)]);
	assert got.field("send").text() == "KeyA:2";
	assert activeHostArrayHeap() == null;
	removeAll(dir);
}

test "a host routine receives a nested struct with a nullable field and returns a struct" {
	implementRoutine("embedTest.decorate", (args: RaiserValue[]): RaiserValue => {
		const d = unboxValue(args[0]);
		const color = d.field("style").field("color");
		const shown = color.root.kind == RaiserValueKind.Nil ? "none" : color.text();
		const echo = `${unboxInt(d.field("row").root)} ${unboxBool(d.field("style").field("bold").root)} ${shown}`;
		return boxValue(hostObject(["accepted", "echo"], [hostValue(boxBool(true)), hostString(echo)]));
	});
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `extern function decorate(d: { row: int32; style: { bold: boolean; color: string | null } }): `
		+ `{ accepted: boolean; echo: string } from "embedTest.decorate";\n`
		+ `export function paint(row: int32, color: string | null): string {\n`
		+ `\tconst r = decorate({ row, style: { bold: row > 1, color } });\n\treturn \`\${r.accepted} \${r.echo}\`;\n}\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const teal = routineValue(interp, "paint", [hostValue(boxInt(3)), hostString("teal")]);
	assert teal.text() == "true 3 true teal";
	const plain = routineValue(interp, "paint", [hostValue(boxInt(1)), hostValue(boxVoid())]);
	assert plain.text() == "true 1 false none";
	removeAll(dir);
}

test "two interpreters in one process each recompile after the other compiled" {
	const dir = scratchDir();
	const kinds = (names: string): string => `import { JsonKind } from "std/serialize/json/types";\nconst kinds: JsonKind[] = [${names}];\n`;
	writeFile(`${dir}/editor.ms`, kinds("JsonKind.Array, JsonKind.Bool") + "console.log(`editor ${kinds[0]} ${kinds.length}`);\n");
	writeFile(`${dir}/app.ms`, "enum Tone { Low, High }\n" + kinds("JsonKind.Bool") + "console.log(`app ${Tone.High} ${kinds[0]}`);\n");
	const editor = testInterpreter();
	const app = testInterpreter();
	assert outputOf(editor, `${dir}/editor.ms`) == "editor Array 2\n";
	assert outputOf(app, `${dir}/app.ms`) == "app High Bool\n";
	writeFile(`${dir}/editor.ms`, kinds("JsonKind.Object") + "console.log(`editor ${kinds[0]} ${kinds.length}`);\n");
	const edited = outputOf(editor, `${dir}/editor.ms`);
	assert edited == "editor Object 1\n", edited;
	writeFile(`${dir}/app.ms`, "enum Tone { Low, High }\n" + kinds("JsonKind.Null") + "console.log(`app ${Tone.Low} ${kinds[0]}`);\n");
	const again = outputOf(app, `${dir}/app.ms`);
	assert again == "app Low Null\n", again;
	removeAll(dir);
}
