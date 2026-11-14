import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const TESTS = `function andAt(text: string, i: int32, word: string): boolean {
	if (text.charCodeAt(i) == word.charCodeAt(0) && text.slice(i, i + word.length) == word) return true;
	return false;
}
function orAt(text: string, i: int32, word: string): boolean {
	if (text.charCodeAt(i) != word.charCodeAt(0) || text.slice(i, i + word.length) != word) return false;
	return true;
}
console.log(andAt("a-ab", 2, "ab") && orAt("a-ab", 2, "ab"));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-shortCircuitFlagThreaded-" + String(Math.floor(Math.random() * 1000000000));
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

function branchesIntoFlagTest(f: RaiserFunction): int32 {
	const lines = disasmFunc(f).split("\n").filter((line: string): boolean => !line.startsWith(";") && line.includes(": "));
	let n: int32 = 0;
	for (let pc = 0; pc < lines.length; pc += 1) {
		const line = lines[pc];
		let target: int64 = -1;
		const arrow = line.indexOf("->");
		if (arrow >= 0) target = pc + 1 + parseInt(line.slice(arrow + 2));
		const jump = line.indexOf(": Jump ");
		if (jump >= 0) target = pc + 1 + parseInt(line.slice(jump + 7));
		if (target >= 0 && target < lines.length && (lines[target].includes(": BTruthy ") || lines[target].includes(": BrEqI64Imm ") || lines[target].includes(": BrNeI64Imm "))) n += 1;
	}
	return n;
}

test "the first operand of an && whose right operand makes a fresh value branches past the flag's test" {
	const f = named(compiled(TESTS), "andAt");
	assert branchesIntoFlagTest(f) == 0, disasmFunc(f);
}

test "the first operand of an || whose right operand makes a fresh value branches past the flag's test" {
	const f = named(compiled(TESTS), "orAt");
	assert branchesIntoFlagTest(f) == 0, disasmFunc(f);
}

function flagStoresLeft(f: RaiserFunction): int32 {
	const lines = disasmFunc(f).split("\n").filter((line: string): boolean => !line.startsWith(";") && line.includes(": "));
	let flag = "";
	for (const line of lines) {
		const at = line.indexOf(": BrEqI64Imm ") >= 0 ? line.indexOf(": BrEqI64Imm ") + 13 : line.indexOf(": BrNeI64Imm ") >= 0 ? line.indexOf(": BrNeI64Imm ") + 13 : -1;
		if (at >= 0) flag = line.slice(at, line.indexOf(" ", at));
	}
	if (flag == "") return -1;
	let n: int32 = 0;
	for (const line of lines) if (line.includes(": LoadConstW " + flag + " ") || line.includes(": LoadInt " + flag + " ")) n += 1;
	return n;
}

test "the flag of a fresh-operand && or || keeps no initial store once its test is branched past" {
	const mod = compiled(TESTS);
	assert flagStoresLeft(named(mod, "andAt")) == 0, disasmFunc(named(mod, "andAt"));
	assert flagStoresLeft(named(mod, "orAt")) == 0, disasmFunc(named(mod, "orAt"));
}
