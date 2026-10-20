import { compileRaiser, runRaiser, setDiagnosticHook } from "../compiler/compile";
import { setRecoverableBuild, BUILD_STOPPED } from "../compiler/io";
import { CliOptions, newCliOptions } from "../compiler/options";
import { ResolveSection, defaultResolveSection } from "../compiler/buildConfig";
import { BuildSession, createBuildSession } from "../compiler/buildSession";
import { ModuleError, ErrorSeverity } from "../module/graph";
import { RaiserModule } from "../raiser/module";
import { RaiserContext } from "../raiser/context";
import { RaiserValue, RaiserValueKind } from "../raiser/value";
import { RaiserHostFn, RaiserHostValue, copyToHost, copyToVm } from "../raiser/marshal";
import { registerHostFn, activeHostArrayHeap, activeHostObjectHeap } from "../raiser/hostRegistry";
import { vmCallFunction, vmDumpStack } from "../raiser/vm";
import { setHostRuntimeDir, resolveRuntimeDir } from "../utils/path";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";
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
	resolve: ResolveSection;
	session: BuildSession;
	run: RaiserContext | null;
	output: string[];
}

export interface Routine {
	name: string;
	mod: RaiserModule;
	funcIdx: int32;
	arity: int32;
}

export { RaiserValue, RaiserValueKind } from "../raiser/value";
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
	hostObject,
	hostArray,
	field,
	length,
	at,
} from "../raiser/marshal";

export function createInterpreter(runtimeRoot: string, searchPaths: string[] = []): Result<Interpreter, string> {
	if (!exists(join(runtimeRoot, "std/core/system/index.ms"))) {
		return Result.err(`no MetaScript std under ${runtimeRoot}: expected ${runtimeRoot}/std/core/system/index.ms`);
	}
	const resolve = defaultResolveSection();
	for (const dir of searchPaths) {
		if (!exists(dir)) return Result.err(`no search path ${dir}: the directory does not exist`);
		resolve.searchPaths.push(dir);
	}
	setHostRuntimeDir(runtimeRoot);
	return Result.ok({ opts: newCliOptions(), resolve, session: createBuildSession(true), run: null, output: [] });
}

function errorAt(file: string, message: string): Diagnostic {
	return { file, line: 0, column: 0, message, severity: ErrorSeverity.Error };
}

export function evalModule(interp: Interpreter, path: string): Result<Evaluation, Diagnostic[]> {
	const diagnostics: Diagnostic[] = [];
	setDiagnosticHook((file: string, e: ModuleError): void => {
		diagnostics.push({ file, line: e.line, column: e.column, message: e.message, severity: e.severity });
	});
	setRecoverableBuild(true);
	interp.run = null;
	let compiled: RaiserModule | null = null;
	try {
		compiled = compileRaiser(path, interp.opts, interp.resolve, interp.session, true);
	} catch (e) {
		if (e.message != BUILD_STOPPED) {
			diagnostics.push(errorAt(path, `internal: ${e.message}`));
			interp.session = createBuildSession(true);
		}
	}
	setRecoverableBuild(false);
	setDiagnosticHook(null);
	if (compiled == null) return Result.err(diagnostics);

	interp.output = [];
	const lines = interp.output;
	const ctx = runRaiser(compiled, [path], (text: string): void => { lines.push(text); });
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
	return Result.ok({ output, exitCode, warnings: diagnostics });
}

export function selectRoutine(interp: Interpreter, name: string): Result<Routine, string> {
	const run = interp.run;
	if (run == null) return Result.err(`no evaluated module to select '${name}' from: the last evalModule failed or none ran`);
	let found: Routine | null = null;
	for (const exported of run.mod.exports) {
		if (exported.name != name) continue;
		if (found != null) return Result.err(`'${name}' is overloaded in the evaluated module; a host selects only a unique routine`);
		found = { name, mod: run.mod, funcIdx: exported.funcIdx, arity: exported.arity };
	}
	if (found == null) return Result.err(`the evaluated module exports no function '${name}'`);
	return Result.ok(found);
}

export function callRoutine(interp: Interpreter, routine: Routine, args: RaiserHostValue[]): Result<RaiserHostValue, string> {
	const run = interp.run;
	if (run == null || run.mod != routine.mod) return Result.err(`'${routine.name}' was selected before the last evalModule; select it again`);
	if (args.length != routine.arity) return Result.err(`'${routine.name}' takes ${routine.arity} argument(s), got ${args.length}`);
	const vm = run.vm!;
	const passed: RaiserValue[] = [];
	for (const arg of args) passed.push(copyToVm(vm.arrayHeap, vm.objectHeap, arg));
	const result = vmCallFunction(vm, routine.funcIdx, passed);
	if (vm.error != "") return Result.err(`raiser runtime error in '${routine.name}': ${vm.error}\n${vmDumpStack(vm)}`);
	return Result.ok(copyToHost(vm.arrayHeap, vm.objectHeap, result));
}

export function implementRoutine(nativeName: string, impl: RaiserHostFn): void {
	registerHostFn(nativeName, impl);
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

test "callRoutine passes floats and strings and returns them" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `export function step(x: number, dt: number): number { return x + 2.5 * dt; }\n`
		+ `export function greet(who: string): string { return \`hi \${who}\`; }\n`);
	const interp = evaluatedInterpreter(`${dir}/main.ms`);
	const step = callRoutine(interp, routineOf(interp, "step"), [hostValue(boxFloat(1.0)), hostValue(boxFloat(0.5))]);
	assert step.ok;
	if (step.ok) assert unboxFloat(step.value.root) == 2.25;
	const greet = callRoutine(interp, routineOf(interp, "greet"), [hostValue(boxString("haro"))]);
	assert greet.ok;
	if (greet.ok) assert unboxString(greet.value.root) == "hi haro";
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
