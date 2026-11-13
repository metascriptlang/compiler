import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const SCANS = `const NAMES: Readonly<string[]> = ["https://", "http://", "mailto:"];
function prefixAt(text: string, i: int32): int32 {
	for (const name of NAMES) {
		if (text.charCodeAt(i) == name.charCodeAt(0) && text.slice(i, i + name.length) == name) return name.length as int32;
	}
	return 0;
}
console.log(prefixAt("see http://x", 4));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-cursorBindingKeepsItsInitializer-" + String(Math.floor(Math.random() * 1000000000));
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

test "a for-of binding the scope never destroys is bound by its element load, with no null stored first" {
	const f = named(compiled(SCANS), "prefixAt");
	const text = disasmFunc(f);
	let nulls = 0;
	for (const line of text.split("\n")) if (line.includes("LoadConst") && line.endsWith("; null")) nulls += 1;
	assert nulls == 1, `expected only the slice temporary's null, got ${nulls}:\n${text}`;
}
