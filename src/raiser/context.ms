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

import { test, check, testGroup } from "std/testing";
import { RaiserValue, RaiserValueKind, raiserNil, raiserInt, raiserToString, raiserIsNil } from "./value";
import { RaiserModule, makeTestModule } from "./module";
import { RaiserOpcode, RaiserInstruction, raiserABC, raiserABx } from "./bytecode";
import { RaiserVM, execModule } from "./vm";

// --- Context ---

export interface RaiserContext {
	mod: RaiserModule;
	hasModule: boolean;
	lastResult: RaiserValue;
	lastOutput: string;
	// TODO: persistent register state / global table for cross-execution state
}

export function createContext(): RaiserContext {
	const haltCode: RaiserInstruction[] = [raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const haltConsts: RaiserValue[] = [raiserNil()];
	const emptyMod = makeTestModule(haltCode, haltConsts);
	const nilResult = raiserNil();
	return { mod: emptyMod, hasModule: false, lastResult: nilResult, lastOutput: "" };
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
	return true;
}

// --- Tests ---

testGroup("RaiserContext", () => {
	test("create + load + execute", () => {
		const ctx = createContext();
		const mod = makeTestModule(
			[raiserABx(RaiserOpcode.LoadConst, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)],
			[raiserInt(42)]
		);
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 42);
	});

	test("execute without load returns false", () => {
		const ctx = createContext();
		const ok = execute(ctx);
		check(!ok);
	});

	test("load replaces module", () => {
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
		check(ctx.lastResult.intVal === 10);

		load(ctx, mod2);
		execute(ctx);
		check(ctx.lastResult.intVal === 20);
	});

	test("output captured", () => {
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
		check(ctx.lastOutput === "99\n");
	});
});
