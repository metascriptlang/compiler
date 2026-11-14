import { compileRaiser, runRaiser } from "../../compiler/compile";
import { newCliOptions } from "../../compiler/options";
import { RaiserModule, RaiserFunction } from "../../raiser/module";
import { RaiserOpcode } from "../../raiser/bytecode";
import { disasmFunc } from "../../raiser/disasm";
import { mkdirExclusive, removeAll, writeFile } from "std/fs";
import { tmpDir } from "std/os";

const COPIES = `class Pane { id: int32 = 0; }
struct Rect { x: int32; y: int32; cols: int32; rows: int32; }
struct Wide extends Rect { depth: int32; }
struct Placed { pane: Pane; rect: Rect; }
struct Moved { id: int32; rect: Rect; }

function moves(placed: Placed[]): Moved[] {
	const out: Moved[] = [];
	for (const p of placed) {
		if (p.rect.cols > 0) out.push({ id: p.pane.id, rect: p.rect });
	}
	return out;
}

const panes = [new Pane(), new Pane()];
panes[1].id = 7;
const wide: Wide = { x: 9, y: 8, cols: 1, rows: 6, depth: 5 };
const placed: Placed[] = [{ pane: panes[0], rect: { x: 1, y: 2, cols: 3, rows: 4 } }, { pane: panes[1], rect: { x: -5, y: 6, cols: 70000, rows: -8 } }, { pane: panes[0], rect: wide }];
let out = "";
for (const m of moves(placed)) out += \` \${m.id}:\${m.rect.x},\${m.rect.y},\${m.rect.cols},\${m.rect.rows}\`;
console.log(out);
`;

interface Run {
	mod: RaiserModule;
	printed: string;
}

function compiledAndRun(source: string): Run {
	const dir = tmpDir() + "/ms-typedStructRead-" + String(Math.floor(Math.random() * 1000000000));
	if (!mkdirExclusive(dir).ok) throw new Error(`cannot create ${dir}`);
	try {
		const file = dir + "/main.ms";
		if (!writeFile(file, source).ok) throw new Error(`cannot write ${file}`);
		const mod = compileRaiser(file, newCliOptions());
		const printed: string[] = [];
		const ctx = runRaiser(mod, [file], (text: string): void => { printed.push(text); }, false);
		return { mod, printed: ctx.lastError != "" ? ctx.lastError : printed.join("|") };
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

test "a struct read from a field of a typed struct is copied slot by slot, with no box and no field lookup by name" {
	const run = compiledAndRun(COPIES);
	assert run.printed == " 0:1,2,3,4 7:-5,6,70000,-8 0:9,8,1,6", run.printed;
	const f = named(run.mod, "moves");
	assert count(f, RaiserOpcode.Box) == 0 && count(f, RaiserOpcode.LoadFieldRequired) == 0 && count(f, RaiserOpcode.IsKind) == 0, disasmFunc(f);
}
