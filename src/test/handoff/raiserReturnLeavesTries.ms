import { compileRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode, getBx } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const RETURNS = `let label: string | null = null;
function swap(next: string | null): string | null {
	const prev = label;
	label = next;
	return prev;
}
function firstLong(words: string[]): string {
	for (const w of words) {
		const t = w + "!";
		if (t.length > 3) return t;
	}
	return "";
}
function guarded(n: int64): int64 {
	let s = "x";
	try {
		if (n > 1) return n;
		s = s + "y";
	} finally {
		label = s;
	}
	return 0;
}
console.log(\`\${swap("a")} \${firstLong(["ab", "abcd"])} \${guarded(2)} \${guarded(0)}\`);
`;

function compiled(source: string): RaiserModule {
	const dir = tmpDir() + "/ms-returnLeavesTries-" + String(Math.floor(Math.random() * 1000000000));
	if (!mkdirExclusive(dir).ok) throw new Error(`cannot create ${dir}`);
	try {
		const file = dir + "/main.ms";
		if (!writeFile(file, source).ok) throw new Error(`cannot write ${file}`);
		return compileRaiser(file, newCliOptions());
	} finally {
		removeAll(dir);
	}
}

function returnsLeaveTheirTries(f: RaiserFunction): boolean {
	const code = f.code;
	for (let r = 0; r < code.length; r += 1) {
		if (code[r].op != RaiserOpcode.Ret && code[r].op != RaiserOpcode.RetN) continue;
		for (let i = 0; i < r; i += 1) {
			if (code[i].op != RaiserOpcode.Try) continue;
			let fin = i + getBx(code[i]);
			if (fin <= r) continue;
			if (code[fin].op == RaiserOpcode.Catch) fin = fin + getBx(code[fin]);
			let left = false;
			for (let k = i + 1; k < r; k += 1) if (code[k].op == RaiserOpcode.Finally && code[k].a == code[fin].a) left = true;
			if (!left) return false;
		}
	}
	return true;
}

test "a return inside a guarded region runs the finally before its Ret instead of routing through it" {
	const mod = compiled(RETURNS);
	let checked = 0;
	for (const f of mod.functions) {
		if (f.name != "swap" && f.name != "firstLong" && f.name != "guarded") continue;
		assert f.code.some((inst): boolean => inst.op == RaiserOpcode.Try), `${f.name} has no Try:\n${disasmFunc(f)}`;
		assert returnsLeaveTheirTries(f), disasmFunc(f);
		checked += 1;
	}
	assert checked == 3;
}
