import { compileRaiser, runRaiser, setDiagnosticHook } from "../compiler/compile";
import { setRecoverableBuild, BUILD_STOPPED } from "../compiler/io";
import { CliOptions, newCliOptions } from "../compiler/options";
import { ModuleError, ErrorSeverity } from "../module/graph";
import { RaiserModule } from "../raiser/module";
import { RaiserValueKind } from "../raiser/value";
import { writeFile, ensureDir, removeAll } from "std/fs";

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
}

export function createInterpreter(): Interpreter {
	return { opts: newCliOptions() };
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
	let compiled: RaiserModule | null = null;
	try {
		compiled = compileRaiser(path, interp.opts);
	} catch (e) {
		if (e.message != BUILD_STOPPED) diagnostics.push(errorAt(path, `internal: ${e.message}`));
	}
	setRecoverableBuild(false);
	setDiagnosticHook(null);
	if (compiled == null) return Result.err(diagnostics);

	const lines: string[] = [];
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
	return Result.ok({ output, exitCode, warnings: diagnostics });
}

function scratchDir(): string {
	const dir = `out/test/embed.${performance.now()}`;
	ensureDir(dir);
	return dir;
}

function outputOf(interp: Interpreter, path: string): string {
	const r = evalModule(interp, path);
	if (r.ok) return r.value.output;
	return `error: ${r.error[0].message}`;
}

test "evalModule runs a module that imports a sibling and std" {
	const dir = scratchDir();
	writeFile(`${dir}/config.ms`, `export const config = { fontFamily: ["OperatorMonoLig Nerd Font Mono"], size: 14 };\n`);
	writeFile(`${dir}/main.ms`, `import { config } from "./config";\nconsole.log(JSON.stringify(config));\n`);
	assert outputOf(createInterpreter(), `${dir}/main.ms`) == `{"fontFamily":["OperatorMonoLig Nerd Font Mono"],"size":14}\n`;
	removeAll(dir);
}

test "evalModule takes a value a macro computed" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `import { Node, NodeKind } from "std/meta";\n`
		+ `macro sameTag(): Node { const a: string[] = ["m", "n"]; return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: a[0] + a[1] == "mn" }; }\n`
		+ `console.log(\`\${sameTag()}\`);\n`);
	assert outputOf(createInterpreter(), `${dir}/main.ms`) == "true\n";
	removeAll(dir);
}

test "evalModule returns a type error as a diagnostic and the host keeps running" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `const size: int32 = "big";\nconsole.log(size);\n`);
	const interp = createInterpreter();
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
	const interp = createInterpreter();
	writeFile(`${dir}/config.ms`, `export const size: int32 = 7;\n`);
	assert outputOf(interp, `${dir}/main.ms`) == "14\n";
	writeFile(`${dir}/config.ms`, `export const size: int32 = 21;\n`);
	assert outputOf(interp, `${dir}/main.ms`) == "42\n";
	removeAll(dir);
}

test "evalModule returns a runtime error and an exit code without leaving the host" {
	const dir = scratchDir();
	writeFile(`${dir}/main.ms`, `const xs: int32[] = [1];\nconsole.log(xs[5]);\n`);
	const interp = createInterpreter();
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
