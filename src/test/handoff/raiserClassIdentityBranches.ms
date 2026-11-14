import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const COMPARES = `class Cell { v: int32 = 0; }
function same(a: Cell, b: Cell): int32 {
	if (a === b) return 1;
	return 0;
}
function differs(a: Cell, b: Cell): int32 {
	if (a !== b) return 1;
	return 0;
}
function sameText(a: string, b: string): int32 {
	if (a === b) return 1;
	return 0;
}
const c = new Cell();
console.log(same(c, c) + differs(c, new Cell()) + sameText("a", "a"));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-classIdentityBranches-" + String(Math.floor(Math.random() * 1000000000));
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

function valueCompares(f: RaiserFunction): int32 {
	return count(f, RaiserOpcode.EqVal) + count(f, RaiserOpcode.NeVal);
}

test "an equality test of two class instances branches on their identity" {
	const f = named(compiled(COMPARES), "same");
	assert valueCompares(f) == 0 && count(f, RaiserOpcode.Jump) == 0, disasmFunc(f);
}

test "an inequality test of two class instances branches on their identity" {
	const f = named(compiled(COMPARES), "differs");
	assert valueCompares(f) == 0 && count(f, RaiserOpcode.Jump) == 0, disasmFunc(f);
}

test "an equality test of two strings compares their text" {
	const f = named(compiled(COMPARES), "sameText");
	assert count(f, RaiserOpcode.EqStr) + count(f, RaiserOpcode.NeStr) == 1, disasmFunc(f);
}
