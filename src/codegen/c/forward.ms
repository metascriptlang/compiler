// C Codegen — Forward Declaration Helpers
//
// Functions that other codegen modules (expressions, statements) need but that
// would create circular imports if left in declarations.ms or index.ms.
// Extracted to break cycles: expressions↔declarations, statements↔declarations, expressions↔index.

import { Type, TypeKind, Symbol, Node, NodeKind, FunctionDeclData, CallingConvention, DecoratedDeclData, ExportDeclData, ProgramData } from "../../ast/node";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { CEmissionFacts, CGen, CSection, addLine, sec, nameSetHas, nameSetAdd, addCGenError } from "./context";
import { ensureDrcProto, procHeader } from "./types";
import { mangledFunctionName } from "./names";
import { placedInstanceOf } from "../../checker/instantiate";

// ===== DRC forward prototypes =====

// ===== Cross-module function prototypes =====

// On-demand cross-module function prototype emission.
// Called from genCallExpr when a cross-module function is referenced.
export function ensureCrossModuleProto(g: CGen, calleeName: string, fnType: Readonly<Type | null>, sym: Readonly<Symbol | null>): void {
	// Recovery path: re-exported symbols imported via a hub module (e.g.,
	// `export { X } from "./source"`) can end up with Unknown symbolType in the
	// caller's scope when the hub's collectExport runs before the source module's
	// Phase 2 resolve completes. Look up the canonical type from the source
	// module's registry entry — by this point (codegen), all modules have been
	// type-checked and the registry holds resolved types.
	if (fnType == null || fnType.kind != TypeKind.Function) return;
	if (sym != null && hasFlag(sym, SymbolFlag.GeneratedOp)) {
		ensureDrcProto(g, calleeName, sym);
		return;
	}
	if (sym != null && copiesInline(g, sym)) {
		requestInlineCopy(g, g.emissionFacts, calleeName, sym);
		return;
	}
	if (sym != null && sym.modulePath != "" && sym.modulePath == g.modulePath) return;
	const protoKey = "proto:" + calleeName;
	if (nameSetHas(g.declaredProcs, protoKey)) return;
	nameSetAdd(g.declaredProcs, protoKey);
	refuseUnboundImageName(g, calleeName, sym);
	const mutBits: int32 = sym != null ? sym.mutatedParams : 0;
	addLine(sec(g, CSection.ProcHeaders), procHeader(g, calleeName, fnType, null, mutBits, false) + ";");
}

export function declareClassInit(g: CGen, initName: string, routine: Readonly<Symbol | null>, initType: Readonly<Type>, mutBits: int32): void {
	if (routine != null && copiesInline(g, routine)) {
		requestInlineCopy(g, g.emissionFacts, initName, routine);
		return;
	}
	const protoKey = "proto:" + initName;
	if (nameSetHas(g.declaredProcs, protoKey)) return;
	nameSetAdd(g.declaredProcs, protoKey);
	refuseUnboundImageName(g, initName, routine);
	addLine(sec(g, CSection.ProcHeaders), procHeader(g, initName, initType, null, mutBits, false) + ";");
}

export function hcrBoundKey(modulePath: string, cName: string): string {
	return modulePath + "\n" + cName;
}

function refuseUnboundImageName(g: CGen, cName: string, routine: Readonly<Symbol | null>): void {
	if (routine == null) return;
	const facts = g.emissionFacts;
	const owner = facts.genericOwners.readonlyGet(cName) ?? routine.modulePath;
	const image = owner == g.modulePath ? null : facts.hcrModules.readonlyGet(owner);
	if (image == null || facts.hcrBoundNames.has(hcrBoundKey(g.modulePath, cName))) return;
	addCGenError(g, `internal: HCR module '${g.modulePath}' names '${cName}' of the reloadable image '${image}' with no binding to it`, 0, 0);
}

export function copiesInline(g: CGen, sym: Readonly<Symbol>): boolean {
	if (sym.symbolType == null || sym.symbolType.callConv != CallingConvention.CcInline) return false;
	if (hasFlag(sym, SymbolFlag.ImportC)) return false;
	if (g.emissionFacts.preludeUnlowered && sym.modulePath != g.modulePath && inlineDeclOf(g.emissionFacts, sym) == null) return false;
	return !g.emissionFacts.hcrModules.has(sym.modulePath);
}

export function factInlineDecls(facts: CEmissionFacts, program: Node): void {
	for (const stmt of (program.data as ProgramData).programStmts) {
		let decl = stmt;
		if (decl.kind == NodeKind.ExportDecl) decl = (decl.data as ExportDeclData).exportedDecl;
		if (decl != null && decl.kind == NodeKind.DecoratedDecl) decl = (decl.data as DecoratedDeclData).decoratedNode;
		if (decl == null || decl.kind != NodeKind.FunctionDecl || decl.nodeType == null || (decl.data as FunctionDeclData).fnBody == null) continue;
		const sym = decl.resolvedSym;
		if (sym != null && sym.symbolType != null && sym.symbolType.callConv == CallingConvention.CcInline) facts.inlineDecls.set(sym!, decl);
	}
}

export function inlineDeclOf(facts: Readonly<CEmissionFacts>, sym: Readonly<Symbol>): Readonly<Node | null> {
	return facts.inlineDecls.readonlyGet(sym);
}

function requestInlineCopy(g: CGen, facts: Readonly<CEmissionFacts>, calleeName: string, called: Readonly<Symbol>): void {
	const key = "inline:" + calleeName;
	if (nameSetHas(g.declaredProcs, key)) return;
	nameSetAdd(g.declaredProcs, key);
	const sym = placedInstanceOf(facts.placedInstances!, called);
	const decl = inlineDeclOf(facts, sym);
	if (decl == null) {
		addCGenError(g, `internal: @inline function '${sym.name}' has no declaration to copy into ${g.modulePath}`, 0, 0);
		return;
	}
	const d = decl.data as FunctionDeclData;
	if (mangledFunctionName(facts.moduleNameRoots!, sym, d.fnName, sym.overloadIdx) != calleeName) {
		addCGenError(g, `internal: @inline function '${sym.name}' is called as '${calleeName}' in ${g.modulePath}`, 0, 0);
		return;
	}
	addLine(sec(g, CSection.ProcHeaders), "static inline " + procHeader(g, calleeName, decl.nodeType!, d.params, sym.mutatedParams, false) + ";");
	g.inlineCopies.push(sym);
}

// useHeader + emitIncludeDirectives moved to context.ms to break types.ms ↔ forward.ms cycle.

import { createStruct, createFunction, createPrimitive } from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";
import { SymbolKind } from "../../ast/node";
import { CheckerContext } from "../../checker/context";
import { createAliveSet, createCGen, extract, factClaimGeneric } from "./context";

test "a function named like a lifecycle hook keeps the ordinary parameter ABI in its prototype" {
	const num = createPrimitive(TypeKind.Float64);
	const big = createStruct("Big", ["a", "b", "c", "d"], [num, num, num, num], true);
	big.sym = makeSymbol("Big", SymbolKind.Struct, big, false);
	const facts = new CEmissionFacts();
	const alive = createAliveSet();
	const g = createCGen(null as unknown as CheckerContext, "", alive, facts);
	ensureCrossModuleProto(g, "MakeCopy", createFunction([big], ["p"], num), null);
	assert extract(sec(g, CSection.ProcHeaders)).contains("double MakeCopy(const Big*);");
}

function imageCall(bound: boolean): CGen {
	const facts = new CEmissionFacts();
	facts.hcrModules.set("/app/text.ms", "text");
	facts.hcrModules.set("/app/bytes.ms", "bytes");
	if (bound) facts.hcrBoundNames.add(hcrBoundKey("/app/text.ms", "makeBytes"));
	const g = createCGen(null as unknown as CheckerContext, "/app/text.ms", createAliveSet(), facts);
	const num = createPrimitive(TypeKind.Float64);
	const fnType = createFunction([num], ["n"], num);
	const routine = makeSymbol("makeBytes", SymbolKind.Function, fnType, false);
	routine.modulePath = "/app/bytes.ms";
	ensureCrossModuleProto(g, "makeBytes", fnType, routine);
	return g;
}

test "an HCR image that names another image's routine with no binding is refused" {
	const g = imageCall(false);
	assert g.errors.length == 1;
	assert g.errors[0].message == "internal: HCR module '/app/text.ms' names 'makeBytes' of the reloadable image 'bytes' with no binding to it";
}

test "an HCR image names a generic instance of another image's generic that it emits itself" {
	const facts = new CEmissionFacts();
	facts.hcrModules.set("/app/text.ms", "text");
	facts.hcrModules.set("/app/bytes.ms", "bytes");
	factClaimGeneric(facts, "box_int32_init", "/app/text.ms", false);
	const g = createCGen(null as unknown as CheckerContext, "/app/text.ms", createAliveSet(), facts);
	const num = createPrimitive(TypeKind.Float64);
	const fnType = createFunction([num], ["n"], num);
	const routine = makeSymbol("box", SymbolKind.Function, fnType, false);
	routine.modulePath = "/app/bytes.ms";
	declareClassInit(g, "box_int32_init", routine, fnType, 0);
	assert g.errors.length == 0;
}

test "an HCR image declares another image's routine it holds a binding to" {
	const g = imageCall(true);
	assert g.errors.length == 0;
	assert extract(sec(g, CSection.ProcHeaders)).contains("double makeBytes(double);");
}
