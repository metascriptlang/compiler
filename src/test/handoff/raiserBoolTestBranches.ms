import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const TESTS = `class Node { next: Node | null = null; n: int32 = 0; }
function pick(flag: boolean, k: int32): int32 {
	if (flag) return 1;
	if (!flag) return 2;
	return k;
}
function walk(head: Node | null): int32 {
	let total: int32 = 0;
	let at = head;
	while (at != null) {
		total += at.n;
		at = at.next;
	}
	return total;
}
const a = new Node(); a.n = 2; const b = new Node(); b.n = 3; a.next = b;
console.log(pick(true, 5) + pick(false, 5) + walk(a));
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-boolTestBranches-" + String(Math.floor(Math.random() * 1000000000));
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

test "a test of a boolean value is one branch, in either sense" {
	const f = named(compiled(TESTS), "pick");
	assert count(f, RaiserOpcode.BTruthy) == 0 && count(f, RaiserOpcode.Jump) == 0, disasmFunc(f);
}

test "a null test of a reference is a kind check and one branch" {
	const f = named(compiled(TESTS), "walk");
	assert count(f, RaiserOpcode.BTruthy) == 0 && count(f, RaiserOpcode.IsKind) == 1, disasmFunc(f);
}
