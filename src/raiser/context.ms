// Raiser VM — Persistent execution context
// Holds VM state across multiple module executions.
//
// Use case: compiler runs build.ms, keeps result, then runs macros
// against the same context — build config visible to macro execution.
//
//   const ctx = createContext();
//   load(ctx, buildModule);
//   execute(ctx);                // build.ms runs, state persists
//   load(ctx, macroModule);
//   execute(ctx);                // macro sees build.ms results

import {
	RaiserValue, RaiserValueKind, raiserNil, raiserInt, raiserToString, raiserIsNil,
	RaiserArrayHeap, createArrayHeap,
	RaiserObjectHeap, createObjectHeap
} from "./value";
import { RaiserModule, makeTestModule } from "./module";
import { RaiserOpcode, RaiserInstruction, raiserABC, raiserABx } from "./bytecode";
import { RaiserVM, execModule, vmDumpStack } from "./vm";

// --- Context ---

export interface RaiserContext {
	mod: RaiserModule;
	hasModule: boolean;
	lastResult: RaiserValue;
	lastOutput: string;
	arrayHeap: RaiserArrayHeap;
	objectHeap: RaiserObjectHeap;
	lastError: string;
}

export function createContext(): RaiserContext {
	const haltCode: RaiserInstruction[] = [raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const haltConsts: RaiserValue[] = [raiserNil()];
	const emptyMod = makeTestModule(haltCode, haltConsts);
	const nilResult = raiserNil();
	const arrayHeap = createArrayHeap();
	const objectHeap = createObjectHeap();
	return { mod: emptyMod, hasModule: false, lastResult: nilResult, lastOutput: "", arrayHeap, objectHeap, lastError: "" };
}

export function load(ctx: RaiserContext, mod: RaiserModule): void {
	ctx.mod = mod;
	ctx.hasModule = true;
}

export function execute(ctx: RaiserContext): boolean {
	if (!ctx.hasModule) return false;
	const vm = execModule(ctx.mod);
	ctx.lastResult = vm.exitValue;
	ctx.lastOutput = vm.output;
	ctx.arrayHeap = vm.arrayHeap;
	ctx.objectHeap = vm.objectHeap;
	if (vm.error !== "") {
		ctx.lastError = vm.error + "\n" + vmDumpStack(vm);
		return false;
	}
	ctx.lastError = "";
	return true;
}

// --- Tests ---
test "create + load + execute" {
	const ctx = createContext();
	const mod = makeTestModule(
		[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[raiserInt(42)]
	);
	load(ctx, mod);
	execute(ctx);
	assert ctx.lastResult.intVal === 42;
}

test "execute without load returns false" {
	const ctx = createContext();
	const ok = execute(ctx);
	assert !ok;
}

test "load replaces module" {
	const ctx = createContext();
	const mod1 = makeTestModule(
		[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[raiserInt(10)]
	);
	const mod2 = makeTestModule(
		[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
		[raiserInt(20)]
	);
	load(ctx, mod1);
	execute(ctx);
	assert ctx.lastResult.intVal === 10;

	load(ctx, mod2);
	execute(ctx);
	assert ctx.lastResult.intVal === 20;
}

test "output captured" {
	const ctx = createContext();
	const mod = makeTestModule(
		[
			raiserABx(RaiserOpcode.LoadConst, 0, 0),
			raiserABC(RaiserOpcode.Print, 0, 0, 0),
			raiserABC(RaiserOpcode.Halt, 0, 0, 0),
		],
		[raiserInt(99)]
	);
	load(ctx, mod);
	execute(ctx);
	assert ctx.lastOutput === "99\n";
}

test "error propagates with stack trace" {
	const ctx = createContext();
	// Unknown opcode should produce error + stack trace
	const code: RaiserInstruction[] = [
		{ op: 999 as RaiserOpcode, a: 0, b: 0, c: 0, cachedIdx: -1, line: 0 },
	];
	const consts: RaiserValue[] = [];
	const mod = makeTestModule(code, consts);
	load(ctx, mod);
	const ok = execute(ctx);
	assert !ok;
	assert ctx.lastError.length > 0;
}
