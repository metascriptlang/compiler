import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const LOOPS = `const LETTERS: Readonly<string[]> = ["h", "e", "l"];
function matchesAt(text: string, i: int32): int32 {
	let hits: int32 = 0;
	for (const w of LETTERS) {
		if (text.charCodeAt(i) == w.charCodeAt(0)) hits += 1;
	}
	return hits;
}
function codes(text: string): int32 {
	let at: int32 = 0;
	let sum: int32 = 0;
	while (at < 3) {
		sum += text.charCodeAt(at);
		at += 1;
	}
	return sum;
}
console.log(matchesAt("hello", 1) + codes("hel"));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-loopInvariantStringRead-" + String(Math.floor(Math.random() * 1000000000));
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

function readsInLoops(f: RaiserFunction): int32 {
	const lines = disasmFunc(f).split("\n").filter((line: string): boolean => !line.startsWith(";") && line.includes(": "));
	const inLoop: boolean[] = lines.map((): boolean => false);
	for (let pc = 0; pc < lines.length; pc += 1) {
		let back: int64 = 0;
		const arrow = lines[pc].indexOf("->-");
		if (arrow >= 0) back = parseInt(lines[pc].slice(arrow + 3));
		const jump = lines[pc].indexOf(": Jump -");
		if (jump >= 0) back = parseInt(lines[pc].slice(jump + 8));
		if (back <= 0) continue;
		for (let k = pc + 1 - back; k <= pc; k += 1) if (k >= 0) inLoop[k] = true;
	}
	let n: int32 = 0;
	for (let pc = 0; pc < lines.length; pc += 1) if (inLoop[pc] && lines[pc].includes(": StrCharCodeAt ")) n += 1;
	return n;
}

test "a string read whose receiver and index a loop never writes is made once, before the loop" {
	const f = named(compiled(LOOPS), "matchesAt");
	assert readsInLoops(f) == 1, disasmFunc(f);
}

test "a string read whose index the loop writes stays in the loop" {
	const f = named(compiled(LOOPS), "codes");
	assert readsInLoops(f) == 1, disasmFunc(f);
}
