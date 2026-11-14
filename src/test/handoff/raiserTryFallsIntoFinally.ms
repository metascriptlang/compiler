import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const TRIES = `let log = "";
function note(s: string): void { log = log + s; }
function guarded(): void {
	try { note("a"); } finally { note("b"); }
}
function caught(): void {
	try { note("c"); } catch (e) { note("x"); } finally { note("d"); }
}
guarded();
caught();
console.log(log);
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-tryFallsIntoFinally-" + String(Math.floor(Math.random() * 1000000000));
	if (!mkdirExclusive(dir).ok) throw new Error(`cannot create ${dir}`);
	try {
		const file = dir + "/main.ms";
		if (!writeFile(file, source).ok) throw new Error(`cannot write ${file}`);
		return compileRaiser(file, newCliOptions());
	} finally {
		removeAll(dir);
	}
}

function named(mod: RaiserModule, name: string): RaiserFunction {
	for (const f of mod.functions) if (f.name == name) return f;
	throw new Error(`no function ${name}`);
}

function count(f: RaiserFunction, op: RaiserOpcode): int32 {
	let n: int32 = 0;
	for (const inst of f.code) if (inst.op == op) n += 1;
	return n;
}

function jumpsBeforeFinally(f: RaiserFunction): int32 {
	let n: int32 = 0;
	for (let i = 1; i < f.code.length; i += 1) {
		if (f.code[i].op == RaiserOpcode.Finally && f.code[i - 1].op == RaiserOpcode.Jump) n += 1;
	}
	return n;
}

test "a try with no catch falls from its body into the finally" {
	const f = named(compiled(TRIES), "guarded");
	assert count(f, RaiserOpcode.Finally) == 1 && jumpsBeforeFinally(f) == 0, disasmFunc(f);
}

test "a try with a catch jumps from its body over the catch into the finally" {
	const f = named(compiled(TRIES), "caught");
	assert count(f, RaiserOpcode.Catch) == 1 && count(f, RaiserOpcode.Jump) >= 1, disasmFunc(f);
}
