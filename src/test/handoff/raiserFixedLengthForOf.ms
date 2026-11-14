import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const LOOPS = `const WORDS: Readonly<string[]> = ["ab", "cd"];
function moduleConst(): int32 {
	let n: int32 = 0;
	for (const w of WORDS) n += w.length as int32;
	return n;
}
function localConst(): int32 {
	const NUMS: Readonly<int32[]> = [1, 2, 3];
	let n: int32 = 0;
	for (const x of NUMS) n += x;
	return n;
}
function parameter(xs: Readonly<int32[]>): int32 {
	let n: int32 = 0;
	for (const x of xs) n += x;
	return n;
}
console.log(moduleConst() + localConst() + parameter([4]));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-fixedLengthForOf-" + String(Math.floor(Math.random() * 1000000000));
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

function lengthReads(f: RaiserFunction): int32 {
	let n: int32 = 0;
	for (const inst of f.code) if (inst.op == RaiserOpcode.ArrayLen) n += 1;
	return n;
}

test "a for-of over a module const read-only array literal reads its length once" {
	const f = named(compiled(LOOPS), "moduleConst");
	assert lengthReads(f) == 1, disasmFunc(f);
}

test "a for-of over a local const read-only array literal reads its length once" {
	const f = named(compiled(LOOPS), "localConst");
	assert lengthReads(f) == 1, disasmFunc(f);
}

test "a for-of over a read-only parameter reads its length again after each element" {
	const f = named(compiled(LOOPS), "parameter");
	assert lengthReads(f) == 2, disasmFunc(f);
}
