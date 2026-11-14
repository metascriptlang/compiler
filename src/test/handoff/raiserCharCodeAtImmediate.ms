import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const READS = `function ends(s: string): int32 {
	return s.charCodeAt(0) + s.charCodeAt(2);
}
function at(s: string, i: int32): int32 {
	return s.charCodeAt(i);
}
console.log(ends("hey") + at("hey", 1));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-charCodeAtImmediate-" + String(Math.floor(Math.random() * 1000000000));
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

test "charCodeAt at a literal index is one instruction that carries the index" {
	const f = named(compiled(READS), "ends");
	assert count(f, RaiserOpcode.StrCharCodeAtImm) == 2 && count(f, RaiserOpcode.LoadInt) == 0, disasmFunc(f);
}

test "charCodeAt at an index held in a register reads that register" {
	const f = named(compiled(READS), "at");
	assert count(f, RaiserOpcode.StrCharCodeAt) == 1 && count(f, RaiserOpcode.StrCharCodeAtImm) == 0, disasmFunc(f);
}
