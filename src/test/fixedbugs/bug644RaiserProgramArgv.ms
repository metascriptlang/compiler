// bug644 — a Raiser program's `argv` was msc's own command line
//
// Symptom:    `msc run tool.ms --target=raiser a "b c"` printed msc, run,
//             tool.ms, --target=raiser, a, b c from `for (const a of argv)`.
// Root cause: the msProcessArgv host bridge returned the host process argv.
// Fix:        the VM carries the program's argv and publishes it to the bridge
//             around each host call; a VM without one (@comptime) still sees
//             the host argv.

import { ensureHostTableLoaded, _resetBridgeStateForTests } from "../../compiler/meta/hostTable";
import { _resetHostRegistryForTests, activeProgramArgv } from "../../raiser/hostRegistry";
import { RaiserValueKind, raiserString, heapArrayLen, heapArrayGet } from "../../raiser/value";
import { RaiserModule, makeTestModule } from "../../raiser/module";
import { RaiserOpcode, RaiserInstruction, raiserABC } from "../../raiser/bytecode";
import { createContext, load, execute } from "../../raiser/context";
import { unboxString } from "../../raiser/marshal";
import { argv } from "std/process";

function bug644Ready(): void {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
}

function bug644Module(): RaiserModule {
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	return makeTestModule(code, [raiserString("msProcessArgv")]);
}

function bug644Run(programArgv: string[] | null): string[] {
	const ctx = createContext();
	ctx.programArgv = programArgv;
	load(ctx, bug644Module());
	const out: string[] = [];
	if (!execute(ctx)) { out.push(ctx.lastError); return out; }
	if (ctx.lastResult.kind != RaiserValueKind.Array) { out.push("not an array"); return out; }
	const n = heapArrayLen(ctx.arrayHeap, ctx.lastResult.intVal);
	let i = 0;
	while (i < n) {
		out.push(unboxString(heapArrayGet(ctx.arrayHeap, ctx.lastResult.intVal, i)));
		i = i + 1;
	}
	return out;
}

test "bug644: a program reads the argv its run was given" {
	bug644Ready();
	const got = bug644Run(["tool/cli.ms", "a", "b c"]);
	assert got.length == 3;
	assert got[0] == "tool/cli.ms";
	assert got[1] == "a";
	assert got[2] == "b c";
}

test "bug644: an empty program argv is empty, not the host's" {
	bug644Ready();
	assert bug644Run([]).length == 0;
}

test "bug644: a run without a program argv still sees the host argv" {
	bug644Ready();
	const got = bug644Run(null);
	assert got.length == argv.length;
}

test "bug644: the program argv does not outlive its host call" {
	bug644Ready();
	bug644Run(["x.ms", "a"]);
	assert activeProgramArgv() == null;
	assert bug644Run(null).length == argv.length;
}
