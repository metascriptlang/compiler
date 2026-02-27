// Raiser codegen — Top-level generator + tests
// AST Program → RaiserModule bytecode.

import { test, check, testGroup } from "std/testing";
import { Node, ProgramData } from "../../ast/node";
import { parseSource } from "../../parser/index";
import { RaiserOpcode } from "../../raiser/bytecode";
import { raiserNil } from "../../raiser/value";
import { RaiserModule, makeTestModule } from "../../raiser/module";
import { createContext, load, execute } from "../../raiser/context";
import {
	RaiserCompState, createCompState, emitInst, addConst, emitLoadConst, emitHalt
} from "./context";
import { compileStmt } from "./statements";
import { raiserABx, raiserABC } from "../../raiser/bytecode";

// --- Top-level: AST → RaiserModule ---

export function generateRaiser(program: Node): RaiserModule {
	const s = createCompState();
	const pd = program.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		compileStmt(s, pd.programStmts[i]);
		i = i + 1;
	}

	// Ensure module terminates
	if (s.code.length === 0) {
		emitLoadConst(s, 0, raiserNil());
		emitHalt(s);
	} else {
		const lastInst = s.code[s.code.length - 1];
		if (lastInst.op !== RaiserOpcode.Ret && lastInst.op !== RaiserOpcode.Halt) {
			emitHalt(s);
		}
	}

	return makeTestModule(s.code, s.constants);
}

// --- Tests ---

testGroup("Raiser codegen", () => {
	test("return number", () => {
		const parseResult = parseSource("return 42;");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 42);
	});

	test("return addition", () => {
		const parseResult = parseSource("return 2 + 3;");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 5);
	});

	test("return complex: 10 - 3 * 2 + 1", () => {
		const parseResult = parseSource("return 10 - 3 * 2 + 1;");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 5);
	});

	test("return negation", () => {
		const parseResult = parseSource("return -7;");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === -7);
	});

	test("console.log captures output", () => {
		const parseResult = parseSource("console.log(42);");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastOutput === "42\n");
	});

	test("console.log expression", () => {
		const parseResult = parseSource("console.log(2 + 3);");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastOutput === "5\n");
	});

	test("(2 + 3) * 4 = 20", () => {
		const parseResult = parseSource("return (2 + 3) * 4;");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 20);
	});

	test("84 / 2 = 42", () => {
		const parseResult = parseSource("return 84 / 2;");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 42);
	});

	test("17 % 5 = 2", () => {
		const parseResult = parseSource("return 17 % 5;");
		check(parseResult.ok);
		const mod = generateRaiser(parseResult.value);
		const ctx = createContext();
		load(ctx, mod);
		execute(ctx);
		check(ctx.lastResult.intVal === 2);
	});
});
