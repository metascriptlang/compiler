import { Type, TypeKind, unknownType } from "./types";
import { Symbol, SymbolKind, SymbolTable, ScopeKind, createSymbolTable, makeSymbol } from "./symbol";
import { Module, ModuleGraph } from "../module/graph";
import { test, check, testGroup } from "std/testing";

// ===== Checker Context =====

export interface CheckerContext {
	table: SymbolTable;
	errors: string[];
	currentFunction: Symbol;   // innermost function (for return type validation)
	inLoop: boolean;           // break/continue validation
	moduleGraph: ModuleGraph;  // null for single-module mode
	currentModule: Module;     // null for single-module mode
}

// ===== Constructors =====

export function createContext(): CheckerContext {
	const table = createSymbolTable();
	return {
		table,
		errors: [],
		currentFunction: null as unknown as Symbol,
		inLoop: false,
		moduleGraph: null as unknown as ModuleGraph,
		currentModule: null as unknown as Module,
	};
}

export function createModuleContext(graph: ModuleGraph, mod: Module): CheckerContext {
	return {
		table: mod.table,
		errors: [],
		currentFunction: null as unknown as Symbol,
		inLoop: false,
		moduleGraph: graph,
		currentModule: mod,
	};
}

// ===== Error Collection =====

export function addError(ctx: CheckerContext, msg: string): void {
	ctx.errors.push(msg);
}

export function hasErrors(ctx: CheckerContext): boolean {
	return ctx.errors.length > 0;
}

export function errorCount(ctx: CheckerContext): number {
	return ctx.errors.length;
}

// ===== Tests =====

testGroup("CheckerContext", () => {
	test("create context", () => {
		const ctx = createContext();
		check(!hasErrors(ctx));
		check(ctx.table.current.scopeKind === ScopeKind.Global);
		check(ctx.currentFunction === null);
		check(!ctx.inLoop);
	});
	test("error collection", () => {
		const ctx = createContext();
		check(errorCount(ctx) === 0);
		addError(ctx, "test error");
		check(hasErrors(ctx));
		check(errorCount(ctx) === 1);
		addError(ctx, "another error");
		check(errorCount(ctx) === 2);
	});
});
