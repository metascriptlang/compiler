// Raiser VM — Hub
// Pure bytecode executor. No source language knowledge.
// `msc test src/raiser/index.ms` is the primary feedback loop.

import { test, check, testGroup } from "std/testing";

// Layer 0: Data types
export { RaiserOpcode, RaiserInstruction, raiserABC, raiserABx, raiserAx, getBx, getSignedBx, getSignedAx } from "./bytecode";
export { RaiserValueKind, RaiserValue, raiserNil, raiserBool, raiserInt, raiserFloat, raiserToInt, raiserToFloat, raiserToBool, raiserIsNil, raiserEqual, raiserToString } from "./value";
export { RaiserCodeBuf, RaiserConstPool, RaiserFunction, RaiserFunctionList, RaiserModule, createRaiserFunction, createRaiserModule, makeTestModule, getModuleEntry, getModuleFunc, getFuncName, getFuncCodeLen, getFuncConstLen, getFuncInst, getFuncConst } from "./module";
export { opName, disasmInst, disasmFunc, printModule } from "./disasm";

// Layer 1: VM executor
export { RaiserVM, createVM, execModule } from "./vm";

// Layer 2: Persistent context (build.ms + macros share state)
export { RaiserContext, createContext, load, execute } from "./context";

// ===== Integration Tests =====

import { RaiserOpcode, raiserABC, raiserABx, raiserAx } from "./bytecode";
import { raiserInt } from "./value";
import { makeTestModule, getModuleEntry, getFuncCodeLen, getFuncInst } from "./module";
import { disasmInst, disasmFunc } from "./disasm";
import { execModule } from "./vm";
import { createContext, load, execute } from "./context";

testGroup("Bytecode Programs", () => {
	test("arithmetic: (2 + 3) * 4 = 20", () => {
		const mod = makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
				raiserABx(RaiserOpcode.LoadConst, 3, 2),
				raiserABC(RaiserOpcode.MulI64, 4, 2, 3),
				raiserABC(RaiserOpcode.Halt, 4, 0, 0),
			],
			[raiserInt(2), raiserInt(3), raiserInt(4)]
		);
		const entry = getModuleEntry(mod);
		check(getFuncCodeLen(entry) === 6);
		check(disasmInst(getFuncInst(entry, 0)) === "LoadConst R0 K0");
		check(disasmInst(getFuncInst(entry, 2)) === "AddI64 R2 R0 R1");
		const vm = execModule(mod);
		check(vm.exitValue.intVal === 20);
	});

	test("branch: if 10 > 5 then 1 else 0", () => {
		const mod = makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.BgtI64, 0, 1, 1),
				raiserAx(RaiserOpcode.Jump, 2),
				raiserABx(RaiserOpcode.LoadConst, 2, 2),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 2, 3),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(10), raiserInt(5), raiserInt(1), raiserInt(0)]
		);
		const vm = execModule(mod);
		check(vm.exitValue.intVal === 1);
	});

	test("loop: sum 1..5 = 15", () => {
		const mod = makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABx(RaiserOpcode.LoadConst, 2, 2),
				raiserABx(RaiserOpcode.LoadConst, 3, 1),
				raiserABC(RaiserOpcode.BgtI64, 1, 2, 3),
				raiserABC(RaiserOpcode.AddI64, 0, 0, 1),
				raiserABC(RaiserOpcode.AddI64, 1, 1, 3),
				raiserAx(RaiserOpcode.Jump, -4),
				raiserABC(RaiserOpcode.Halt, 0, 0, 0),
			],
			[raiserInt(0), raiserInt(1), raiserInt(5)]
		);
		const vm = execModule(mod);
		check(vm.exitValue.intVal === 15);
	});

	test("disassembly output", () => {
		const mod = makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABC(RaiserOpcode.AddI64, 1, 0, 0),
				raiserAx(RaiserOpcode.Jump, -1),
				raiserABC(RaiserOpcode.Halt, 1, 0, 0),
			],
			[raiserInt(99)]
		);
		const entry = getModuleEntry(mod);
		const s = disasmFunc(entry);
		check(s.length > 0);
	});
});

testGroup("Context E2E", () => {
	test("load + execute", () => {
		const ctx = createContext();
		const mod = makeTestModule(
			[
				raiserABx(RaiserOpcode.LoadConst, 0, 0),
				raiserABx(RaiserOpcode.LoadConst, 1, 1),
				raiserABC(RaiserOpcode.AddI64, 2, 0, 1),
				raiserABC(RaiserOpcode.Halt, 2, 0, 0),
			],
			[raiserInt(10), raiserInt(32)]
		);
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 42);
	});

	test("sequential modules", () => {
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
});
