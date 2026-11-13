import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const REORDERS = `class Item { id: int32 = 0; }
function item(id: int32): Item { const it = new Item(); it.id = id; return it; }
const xs: Item[] = [item(1), item(2), item(3), item(4)];
xs.splice(1, 1);
xs.splice(0, 1, item(9));
xs.reverse();
let out = "";
for (const x of xs) out = out + " " + x.id.toString();
console.log(out);
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-spliceMovesElements-" + String(Math.floor(Math.random() * 1000000000));
	if (!mkdirExclusive(dir).ok) throw new Error(`cannot create ${dir}`);
	try {
		const file = dir + "/main.ms";
		if (!writeFile(file, source).ok) throw new Error(`cannot write ${file}`);
		return compileRaiser(file, newCliOptions());
	} finally {
		removeAll(dir);
	}
}

function counts(f: RaiserFunction): boolean {
	return f.code.some((inst): boolean => inst.op == RaiserOpcode.RcInc || inst.op == RaiserOpcode.RcDec);
}

function runs(f: RaiserFunction, op: RaiserOpcode): boolean {
	return f.code.some((inst): boolean => inst.op == op);
}

test "splice and reverse of a class array move its elements in the VM without counting them" {
	const mod = compiled(REORDERS);
	let removal = 0;
	let replacement = 0;
	let reversal = 0;
	for (const f of mod.functions) {
		if (runs(f, RaiserOpcode.ArraySplice)) removal += 1;
		if (runs(f, RaiserOpcode.ArraySplice3)) replacement += 1;
		if (runs(f, RaiserOpcode.ArrayReverse)) reversal += 1;
		if (!f.name.includes("splice") && !f.name.includes("reverse")) continue;
		assert !counts(f), disasmFunc(f);
	}
	assert removal == 1 && replacement == 1 && reversal == 1, `ArraySplice ${removal}, ArraySplice3 ${replacement}, ArrayReverse ${reversal}`;
}
