import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const LOOPS = `const NAMES: Readonly<string[]> = ["https://", "http://", "mailto:"];
let seen: int32 = 0;
function prefixAt(text: string, i: int32): int32 {
	for (const name of NAMES) {
		if (text.charCodeAt(i) == name.charCodeAt(0)) return name.length as int32;
	}
	return 0;
}
function countSeen(n: int32): int32 {
	for (let i: int32 = 0; i < n; i += 1) seen += 1;
	return seen;
}
console.log(prefixAt("see http://x", 4) + countSeen(2));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-constBindingLoadedBeforeLoop-" + String(Math.floor(Math.random() * 1000000000));
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

function globalLoadsInLoops(f: RaiserFunction): int32 {
	const lines = disasmFunc(f).split("\n").filter((line: string): boolean => !line.startsWith(";") && line.includes(": "));
	const inLoop: boolean[] = lines.map((): boolean => false);
	for (let pc = 0; pc < lines.length; pc += 1) {
		const at = lines[pc].indexOf("->-");
		if (at < 0) continue;
		const target = pc + 1 - parseInt(lines[pc].slice(at + 3));
		for (let k = target; k <= pc; k += 1) inLoop[k] = true;
	}
	let n: int32 = 0;
	for (let pc = 0; pc < lines.length; pc += 1) if (inLoop[pc] && lines[pc].includes(": LoadGlobal ")) n += 1;
	return n;
}

test "a loop over a const module binding reads it from a register loaded before the loop" {
	const f = named(compiled(LOOPS), "prefixAt");
	assert globalLoadsInLoops(f) == 0 && count(f, RaiserOpcode.LoadGlobal) > 0, disasmFunc(f);
}

test "a loop writing a let module binding reads and writes its slot on every iteration" {
	const f = named(compiled(LOOPS), "countSeen");
	assert globalLoadsInLoops(f) >= 1 && count(f, RaiserOpcode.StoreGlobal) >= 1, disasmFunc(f);
}
