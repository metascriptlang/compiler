// guard: a lifecycle hook is bound to its type at the declaration, or refused there.
//
// INVARIANT: a hook the compiler accepts is a hook that runs. The reference binds a hook to its
//   type in `bindHookToType` and refuses one that cannot bind: a type bound operation can be defined
//   only in the module of its type (semstmts 2205-2207), and a wrong signature is "signature for
//   '=…' must be …" (semstmts 2220-2260, `bindDupHook` 2192-2203).
//
// WHY A SUBPROCESS: the observable is the CLI verdict on C and on JS; the compiler under test is
//   $MSC when the runner exports one, else `./msc` beside the recompiler root.
//
// RED MEANS: a declaration the reference refuses, or one that cannot run, was accepted (it failed
//   later in the C compiler or never ran), or a declaration the reference binds was refused.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

interface Source {
	path: string;
	text: string;
}

interface Case {
	name: string;
	files: Source[];
	refused: string;
	runs: string;
}

const cases: Case[] = [];

function refuse(name: string, refused: string, files: Source[]): void {
	cases.push({ name, files, refused, runs: "" });
}

function accept(name: string, files: Source[]): void {
	cases.push({ name, files, refused: "", runs: "" });
}

function runsOrc(name: string, printed: string, files: Source[]): void {
	cases.push({ name, files, refused: "", runs: printed });
}

function one(text: string): Source[] {
	return [{ path: "main.ms", text }];
}

const libStruct = "export struct S { id: int32; name: string; }\n";

refuse("a hook declared outside the module of its type", "type bound operation 'onDestroy' can be defined only in the same module with its type (S)", [
	{ path: "lib.ms", text: libStruct },
	{ path: "main.ms", text: "import { S } from \"./lib\";\nfunction onDestroy(this x: S): void { console.log(\"destroy\"); }\nconst a: S = { id: 1, name: \"n\" };\nconsole.log(a.id.toString());\n" },
]);

accept("a hook declared beside its type, used from another module", [
	{ path: "lib.ms", text: libStruct + "export function onDestroy(this x: S): void { console.log(\"destroy\"); }\n" },
	{ path: "main.ms", text: "import { S } from \"./lib\";\nconst a: S = { id: 1, name: \"n\" };\nconsole.log(a.id.toString());\n" },
]);

const cyclic = "class N { id: int32 = 0; next: N | null = null; }\n";
const cycle = "function run(): void {\n\tconst a = new N();\n\tconst b = new N();\n\ta.id = 1;\n\tb.id = 2;\n\ta.next = b;\n\tb.next = a;\n}\nrun();\nconsole.log(\"end\");\n";

runsOrc("onTrace takes the tracer and runs under the cycle collector", "trace", one(
	cyclic + "function onTrace(this x: N, env: Ptr<void>): void { console.log(\"trace \" + x.id.toString()); }\n" + cycle));

refuse("onTrace without the tracer", "signature for 'onTrace' is wrong: it takes the receiver and the tracer ('env: Ptr<void>'), 1 parameter declared", one(
	cyclic + "function onTrace(this x: N): void { console.log(\"trace\"); }\n" + cycle));

refuse("onTrace with a tracer of another type", "signature for 'onTrace' is wrong: its second parameter is 'int32', the tracer is 'env: Ptr<void>'", one(
	cyclic + "function onTrace(this x: N, env: int32): void { console.log(\"trace\"); }\n" + cycle));

refuse("an onTrace method without the tracer", "signature for 'onTrace' is wrong: it takes the receiver and the tracer ('env: Ptr<void>'), 1 parameter declared", one(
	"class N { id: int32 = 0; next: N | null = null; onTrace(): void { console.log(\"trace\"); } }\n" + cycle));

const valueStruct = "struct S { id: int32; name: string; }\n";
const useStruct = "const a: S = { id: 1, name: \"n\" };\nconsole.log(a.id.toString());\n";

refuse("onDestroy with a second parameter", "signature for 'onDestroy' is wrong: it takes the receiver only, 2 parameters declared", one(
	valueStruct + "function onDestroy(this x: S, extra: int32): void { console.log(\"destroy\"); }\n" + useStruct));

refuse("onCopy with a source of another type", "signature for 'onCopy' is wrong: its second parameter is 'int32', the source value is the receiver's own type ('y: T')", one(
	valueStruct + "function onCopy(this ref x: S, y: int32): void { console.log(\"copy\"); }\n" + useStruct));

refuse("onDestroy that returns a value", "signature for 'onDestroy' is wrong: it returns 'int32', a hook returns nothing", one(
	valueStruct + "function onDestroy(this x: S): int32 { console.log(\"destroy\"); return 1; }\n" + useStruct));

refuse("onClone that returns another type", "signature for 'onClone' is wrong: it returns 'int32', a clone is a new value of the receiver's own type", one(
	valueStruct + "function onClone(this x: S): int32 { return 1; }\n" + useStruct));

refuse("onCopy on a class", "is a class, its values are shared by reference and never copied, moved or cloned by value, so the hook would never run", one(
	"class K { id: int32 = 0; }\nfunction onCopy(this x: K, y: K): void { console.log(\"copy\"); }\nconst k = new K();\nconsole.log(k.id.toString());\n"));

accept("every hook of a struct with the signature the reference binds", one(valueStruct
	+ "function onDestroy(this x: S): void { }\nfunction onCopy(this ref x: S, y: S): void { }\nfunction onMove(this ref x: S, y: S): void { }\n"
	+ "function onMoved(this ref x: S): void { }\nfunction onClone(this x: S): S { return x; }\n" + useStruct));

function verdict(dir: string, target: string): string {
	const args = target == "c" ? ["check", `${dir}/main.ms`] : ["check", `${dir}/main.ms`, "--target=js"];
	const r = execFileResult(msc, args);
	return `${r.exitCode == 0 ? "OK" : "ERR"}\n${r.output}${r.errorOutput}`;
}

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/hookDeclarations/${slot}`;
	ensureDir(dir);
	for (const f of c.files) writeFile(`${dir}/${f.path}`, f.text);
	if (c.runs != "") {
		const r = execFileResult(msc, ["run", "--gc=orc", `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		if (r.exitCode != 0) report(`[orc] ${c.name}: did not build and run: ${out}`);
		else if (!out.includes(c.runs)) report(`[orc] ${c.name}: the hook never printed '${c.runs}': ${out}`);
		continue;
	}
	for (const target of ["c", "js"]) {
		const out = verdict(dir, target);
		const accepted = out.startsWith("OK\n");
		if (c.refused == "") {
			if (!accepted) report(`[${target}] ${c.name}: refused: ${out}`);
		} else if (accepted) {
			report(`[${target}] ${c.name}: accepted`);
		} else if (!out.includes(c.refused)) {
			report(`[${target}] ${c.name}: refused without the rule named (${c.refused}): ${out}`);
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
