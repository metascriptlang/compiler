// DRC Analyzer Hub — entry point for Phase 4 (RC injection)
//
// Pipeline: parse → check → transform → **analyze** → codegen
//
// analyzeProgram is the main entry point called from src/index.ms.

import { Node, NodeKind, NodeFlag, ProgramData, BlockStmtData, CallingConvention, ExportDeclData, FunctionDeclData, Symbol, SymbolKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { flowLap, flowMark } from "../compiler/flows";
import { RoutineFlag, hasFlag, routineFlagSet, SymbolFlag } from "../checker/symbol";
import { CheckerContext, GcMode, dispatchEntryFor, nextDisamb } from "../checker/context";
import { createTransformContextWithChecker } from "../transform/context";
import { createDrcContext, pushScope, popScope } from "./scope";
import { injectProgram, isGeneratorBody } from "./inject";
import { optimizeDrc } from "./optimize";
import { inferCursors } from "./cursors";
import { cloneNodeKeepSem } from "../monomorphize/clone";
import { WriteEffects, WriteSummaries, borrowedArgsToCopy, callbackParams, callerDefsOf, createRoutineDecls, createWriteSummaries, forwardedTo, lendCallbacks, leaveRoutineLending, noteRoutineDecls, openContract, settleContract } from "./writeEffects";
import { classifyType, RcKind, noRcInfo } from "./classify";

import { parseSource } from "../parser/statements/validation";
import { checkProgram } from "../checker/checkPass";
import { transformProgram } from "../transform/index";

// ===== Public Entry Point =====

export function analyzeProgram(program: Node, checkerCtx: CheckerContext, tables: WriteSummaries): Node {
	if (checkerCtx == null) return program;  // test mode — skip analysis
	if (checkerCtx.gcMode == GcMode.None || checkerCtx.gcMode == GcMode.Manual) return program;
	flowMark();
	const ctx = createTransformContextWithChecker(checkerCtx);
	const dctx = createDrcContext(ctx, tables);
	noteRoutineDecls(dctx.writes, program);
	cloneCallbackReaders(dctx.writes, program);
	flowLap("analyze.context");
	const injected = injectProgram(program, dctx);
	flowLap("analyze.inject");
	const optimized = optimizeDrc(injected);
	flowLap("analyze.optimize");
	return optimized;
}

function callbackReader(w: WriteEffects, stmt: Node): Node | null {
	const decl = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
	if (decl == null || decl.kind != NodeKind.FunctionDecl || decl.nodeType == null) return null;
	const sym = decl.resolvedSym;
	const d = decl.data as FunctionDeclData;
	if (sym == null || sym.symbolKind != SymbolKind.Function || sym.modulePath != w.unit) return null;
	if (d.fnBody == null || d.fnBody.kind != NodeKind.BlockStmt || routineFlagSet(d.fnFlags).has(RoutineFlag.Generic) || routineFlagSet(d.fnFlags).has(RoutineFlag.Extern)) return null;
	if (sym.overloads.length > 0 || sym.overloadIdx != 0 || sym.exportName != "" || sym.nativeName != "" || dispatchEntryFor(sym) != null) return null;
	if (hasFlag(sym, SymbolFlag.ImportC) || hasFlag(sym, SymbolFlag.GeneratedOp) || hasFlag(sym, SymbolFlag.OverloadSig) || hasFlag(sym, SymbolFlag.Borrow) || hasFlag(sym, SymbolFlag.CompileTime)) return null;
	if (sym.symbolType == null || sym.symbolType.callConv == CallingConvention.CcInline || isGeneratorBody(d.fnBody)) return null;
	return decl;
}

function copySymbol(s: Symbol): Symbol {
	return {
		name: s.name, nameId: s.nameId, symbolKind: s.symbolKind, symbolType: s.symbolType, state: s.state, location: s.location,
		declNode: s.declNode, overloads: s.overloads, nativeName: s.nativeName, exportName: s.exportName, builtinKind: s.builtinKind,
		symFlags: s.symFlags, defaultParams: s.defaultParams, modulePath: s.modulePath, headerPath: s.headerPath, jsModulePath: s.jsModulePath,
		overloadIdx: s.overloadIdx, disamb: s.disamb, mutatedParams: s.mutatedParams, staticFields: s.staticFields,
		fieldDecoratorNames: s.fieldDecoratorNames, fieldDecorators: s.fieldDecorators, metaKeys: s.metaKeys, metaValues: s.metaValues,
		nonisolatedFields: s.nonisolatedFields, duVariantSlot: s.duVariantSlot, itemModule: s.itemModule, item: s.item,
		instantiatedFrom: s.instantiatedFrom, borrowedFrom: s.borrowedFrom, staticOwner: s.staticOwner, typeParams: s.typeParams,
	};
}

function isFrameSymbol(sym: Symbol): boolean {
	return (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Temp || sym.symbolKind == SymbolKind.Parameter)
		&& !hasFlag(sym, SymbolFlag.Global) && !hasFlag(sym, SymbolFlag.StaticLocal);
}

function cloneRoutine(w: WriteEffects, decl: Node): Node {
	const fn = decl.resolvedSym!;
	const copy = cloneNodeKeepSem(decl);
	const fresh = new HashMap<Symbol, Symbol>();
	const own = (sym: Symbol): Symbol => {
		if (!isFrameSymbol(sym)) return sym;
		const known = fresh.get(sym);
		if (known != null) return known;
		const c = copySymbol(sym);
		fresh.set(sym, c);
		return c;
	};
	const step = (n: Node): void => {
		if (n.resolvedSym != null) {
			const before = n.resolvedSym!;
			n.resolvedSym = own(before);
			if (n.resolvedSym !== before && n.kind == NodeKind.VariableDecl) n.resolvedSym!.declNode = n;
		}
		if (n.paramSyms != null) {
			const mapped: Symbol[] = [];
			for (const p of n.paramSyms!) mapped.push(own(p));
			n.paramSyms = mapped;
		}
		forEachChild(n, step);
	};
	forEachChild(copy, step);
	if (copy.paramSyms != null) {
		const mapped: Symbol[] = [];
		for (const p of copy.paramSyms!) mapped.push(own(p));
		copy.paramSyms = mapped;
	}
	for (const c of fresh.values()) {
		if (c.borrowedFrom != null) c.borrowedFrom = own(c.borrowedFrom!);
	}
	const name = fn.name + "$lent";
	let clone = w.tables.reusedClones.get(fn);
	if (clone == null) {
		clone = copySymbol(fn);
		clone.name = name;
		clone.overloads = [];
		clone.instantiatedFrom = null;
		clone.disamb = w.checker != null ? nextDisamb(w.checker!, fn.modulePath, name) : fn.disamb;
	}
	clone!.declNode = copy;
	copy.resolvedSym = clone;
	(copy.data as FunctionDeclData).fnName = name;
	return copy;
}

function isRoutineNode(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ConstructorDecl
		|| n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ClassDecl;
}

function heldAcrossCallbacks(w: WriteEffects, decl: Node, params: int32[], held: string[], forwards: Symbol[]): void {
	const callbacks: Symbol[] = [];
	for (const i of params) callbacks.push(decl.paramSyms![i]);
	const body = (decl.data as FunctionDeclData).fnBody;
	const outer = lendCallbacks(w, callbacks, held);
	try {
		const defs = inferCursors(w, body) ?? callerDefsOf(w, body);
		const step = (n: Node): void => {
			if (isRoutineNode(n)) return;
			if (n.kind == NodeKind.CallExpr) {
				borrowedArgsToCopy(w, n, defs);
				const target = forwardedTo(w, n);
				if (target != null && !forwards.includes(target!)) forwards.push(target!);
			}
			forEachChild(n, step);
		};
		step(body);
	} finally {
		leaveRoutineLending(w, outer);
	}
}

function cloneCallbackReaders(w: WriteEffects, program: Node): void {
	w.tables.unitContracts = [];
	const stmts = (program.data as ProgramData).programStmts;
	const at: int32[] = [];
	const fns: Symbol[] = [];
	const clones: Node[] = [];
	for (let i = 0; i < stmts.length; i += 1) {
		const decl = callbackReader(w, stmts[i]);
		if (decl == null) continue;
		const params = callbackParams(w, decl);
		if (params.length == 0) continue;
		const clone = cloneRoutine(w, decl);
		const held: string[] = [];
		const forwards: Symbol[] = [];
		heldAcrossCallbacks(w, clone, params, held, forwards);
		openContract(w, decl.resolvedSym!, params, clone.resolvedSym!, held, forwards);
		at.push(i as int32);
		fns.push(decl.resolvedSym!);
		clones.push(clone);
	}
	if (clones.length == 0) return;
	const kept: (Node | null)[] = [];
	for (let k = 0; k < clones.length; k += 1) kept.push(settleContract(w, fns[k]) != null ? clones[k] : null);
	const out: Node[] = [];
	const decls = w.tables.routineDecls;
	const unitSyms = decls.unitRoutines.get(w.unit);
	let k = 0;
	for (let i = 0; i < stmts.length; i += 1) {
		out.push(stmts[i]);
		if (k < at.length && at[k] == i) {
			const clone = kept[k];
			if (clone != null) {
				out.push(clone);
				decls.decls.set(clone.resolvedSym!, clone);
				decls.routineUnits.set(clone.resolvedSym!, w.unit);
				if (unitSyms != null) unitSyms.push(clone.resolvedSym!);
			}
			k += 1;
		}
	}
	(program.data as ProgramData).programStmts = out;
}

// ===== Integration Tests =====

function analyzePipeline(input: string): Node {
	const parseResult = parseSource(input);
	if (!parseResult.ok) return null as unknown as Node;
	const program = parseResult.value;
	const checkerCtx = checkProgram(program);
	const transformed = transformProgram(program, checkerCtx, false);
	return analyzeProgram(transformed, checkerCtx, createWriteSummaries(createRoutineDecls(), []));
}

function getStmtCount(program: Node): number {
	if (program == null) return 0;
	if (program.kind != NodeKind.Program) return 0;
	const d = program.data as ProgramData;
	return d.programStmts.length;
}

test "primitives pass through unchanged" {
	const result = analyzePipeline("const x = 1; const y = 2;");
	assert result != null;
	// Primitive-only code: no RC calls inserted
	assert getStmtCount(result) == 2;
}

test "null checker skips analysis" {
	const parseResult = parseSource("const x = 1;");
	if (!parseResult.ok) {
		assert false;
		return;
	}
	const program = parseResult.value;
	const result = analyzeProgram(program, null as unknown as CheckerContext, createWriteSummaries(createRoutineDecls(), []));
	assert result != null;
	// Should return program unchanged
	assert getStmtCount(result) == 1;
}

test "function with primitives" {
	const result = analyzePipeline("function add(a: number, b: number): number { return a + b; }");
	assert result != null;
}

test "empty program" {
	const result = analyzePipeline("");
	assert result != null;
	assert getStmtCount(result) == 0;
}

function destroyedGlobal(stmt: Node): string {
	let found = "";
	const visit = (n: Node): void => {
		if (found != "") return;
		if (n.kind == NodeKind.Identifier && n.resolvedSym != null && hasFlag(n.resolvedSym, SymbolFlag.Global)) {
			found = n.resolvedSym.name;
			return;
		}
		forEachChild(n, visit);
	};
	visit(stmt);
	return found;
}

test "module globals are destroyed in reverse declaration order at program end, each emptied after its release" {
	const result = analyzePipeline("const first: string[] = [\"a\"];\nconst second: string[] = [\"b\"];\nconsole.log(first.length + second.length);");
	const stmts = (result.data as ProgramData).programStmts;
	const exitBlock = stmts[stmts.length - 1];
	assert exitBlock.kind == NodeKind.BlockStmt && exitBlock.flags.has(NodeFlag.GlobalDestroys);
	const destroys = (exitBlock.data as BlockStmtData).statements;
	assert destroys.length == 4;
	assert destroyedGlobal(destroys[0]) == "second" && destroyedGlobal(destroys[1]) == "second";
	assert destroyedGlobal(destroys[2]) == "first" && destroyedGlobal(destroys[3]) == "first";
}

test "a program without owned globals carries no global destroys" {
	const result = analyzePipeline("const n = 1;\nfunction f(): string[] { return [\"x\"]; }\nconsole.log(f().length + n);");
	for (const s of (result.data as ProgramData).programStmts) assert !s.flags.has(NodeFlag.GlobalDestroys);
}

// Phase E field-level move patterns are covered by the full integration test suite (2186+ tests).
// The field-level CFG, alias-aware BFS, and injection paths are validated end-to-end
// through compile-and-run tests rather than isolated AST inspection.
