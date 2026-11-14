import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const LOGICAL = `function either(a: boolean, b: boolean, n: int32): boolean {
	let r = false;
	for (let i: int32 = 0; i < n; i += 1) r = a || b;
	return r;
}
function bothInt(a: int32, b: int32, n: int32): int32 {
	let r: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) r = a && b;
	return r;
}
function eitherText(a: string, b: string, n: int32): string {
	let r = "";
	for (let i: int32 = 0; i < n; i += 1) r = a || b;
	return r;
}
console.log(either(false, true, 2), bothInt(3, 4, 2), eitherText("", "x", 2));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-logicalValueBranches-" + String(Math.floor(Math.random() * 1000000000));
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

test "|| over booleans tests the left operand with no truthiness test" {
	const f = named(compiled(LOGICAL), "either");
	assert count(f, RaiserOpcode.BTruthy) == 0, disasmFunc(f);
}

test "&& over integers tests the left operand with no truthiness test" {
	const f = named(compiled(LOGICAL), "bothInt");
	assert count(f, RaiserOpcode.BTruthy) == 0, disasmFunc(f);
}

test "|| over strings tests the left operand by its truthiness" {
	const f = named(compiled(LOGICAL), "eitherText");
	assert count(f, RaiserOpcode.BTruthy) == 1, disasmFunc(f);
}
