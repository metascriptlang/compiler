import { ensureHostTableLoaded, _resetBridgeStateForTests } from "../../compiler/meta/hostTable";
import { _resetHostRegistryForTests, setActiveProgramArgv, activeProgramArgv } from "../../raiser/hostRegistry";
import { RaiserValueKind, raiserString, heapArrayLen, heapArrayGet } from "../../raiser/value";
import { RaiserModule, makeTestModule } from "../../raiser/module";
import { RaiserOpcode, RaiserInstruction, raiserABC } from "../../raiser/bytecode";
import { createContext, load, execute } from "../../raiser/context";
import { unboxString } from "../../raiser/marshal";
import { argv } from "std/process";

function prepareProgramArgvHost(): void {
	_resetHostRegistryForTests();
	_resetBridgeStateForTests();
	ensureHostTableLoaded();
}

function processArgvModule(): RaiserModule {
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.CallHost, 0, 0, 0),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	];
	return makeTestModule(code, [raiserString("msProcessArgv")]);
}

function argvSeenBy(programArgv: string[] | null): string[] {
	const ctx = createContext();
	ctx.programArgv = programArgv;
	load(ctx, processArgvModule());
	const out: string[] = [];
	if (!execute(ctx)) { out.push(ctx.lastError); return out; }
	if (ctx.lastResult.kind != RaiserValueKind.Array) { out.push("not an array"); return out; }
	const n = heapArrayLen(ctx.arrayHeap, ctx.lastResult.intVal);
	for (let i = 0; i < n; i += 1) {
		out.push(unboxString(heapArrayGet(ctx.arrayHeap, ctx.lastResult.intVal, i)));
	}
	return out;
}

test "raiserProgramArgv: a program reads the argv its run was given" {
	prepareProgramArgvHost();
	const got = argvSeenBy(["tool/cli.ms", "a", "b c"]);
	assert got.length == 3;
	assert got[0] == "tool/cli.ms";
	assert got[1] == "a";
	assert got[2] == "b c";
}

test "raiserProgramArgv: an empty program argv is empty, not the host's" {
	prepareProgramArgvHost();
	assert argv.length > 0;
	assert argvSeenBy([]).length == 0;
}

test "raiserProgramArgv: a run without a program argv reads the host argv" {
	prepareProgramArgvHost();
	const got = argvSeenBy(null);
	assert got.length == argv.length;
	for (let i = 0; i < got.length; i += 1) {
		assert got[i] == argv[i];
	}
}

test "raiserProgramArgv: the program argv does not outlive its host call" {
	prepareProgramArgvHost();
	argvSeenBy(["x.ms", "a"]);
	assert activeProgramArgv() == null;
	assert argvSeenBy(null).length == argv.length;
}

test "raiserProgramArgv: a nested run restores the argv the outer host call published" {
	prepareProgramArgvHost();
	setActiveProgramArgv(["outer.ms"]);
	argvSeenBy(["inner.ms", "a"]);
	const restored = activeProgramArgv();
	assert restored != null;
	if (restored != null) {
		assert restored.length == 1;
		assert restored[0] == "outer.ms";
	}
	setActiveProgramArgv(null);
}
