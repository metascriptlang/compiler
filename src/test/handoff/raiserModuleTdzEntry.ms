import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule } from "../../raiser/module";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const READERS = `class P { x: int64 = 0; constructor(x: int64) { this.x = x; } }
function make(): int64 { return 1; }
const k = make();
const origin = new P(3);
let counter: int64 = 2;
function readObj(): int64 { let s: int64 = 0; for (let i: int64 = 0; i < 3; i = i + 1) s = s + origin.x; return s; }
function readInt(): int64 { let s: int64 = 0; for (let i: int64 = 0; i < 3; i = i + 1) { s = s + counter; s = s + counter; } return s; }
console.log(\`\${k} \${readObj()} \${readInt()}\`);
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-moduleTdzEntry-" + String(Math.floor(Math.random() * 1000000000));
	if (!mkdirExclusive(dir).ok) throw new Error(`cannot create ${dir}`);
	try {
		const file = dir + "/main.ms";
		if (!writeFile(file, source).ok) throw new Error(`cannot write ${file}`);
		return compileRaiser(file, newCliOptions());
	} finally {
		removeAll(dir);
	}
}

function guards(mod: RaiserModule, name: string, binding: string): int32 {
	for (const f of mod.functions) {
		if (f.name != name) continue;
		let n: int32 = 0;
		for (const text of f.names) if (text == binding) n += 1;
		return n;
	}
	throw new Error(`no function ${name}`);
	return -1;
}

test "a module binding read only by routines no statement enters before its declaration carries no guard" {
	const mod = compiled(READERS);
	assert guards(mod, "readObj", "origin") == 0 && guards(mod, "readInt", "counter") == 0, disasmFunc(mod.functions[0]);
}

test "a module binding read by a routine a statement references before its declaration keeps its guard" {
	const mod = compiled(READERS.replace("const origin = new P(3);", "const readers = [readObj, readInt];\nconst origin = new P(3);"));
	assert guards(mod, "readObj", "origin") >= 1 && guards(mod, "readInt", "counter") >= 1;
}
