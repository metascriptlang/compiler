// C Codegen — Forward Declaration Helpers
//
// Functions that other codegen modules (expressions, statements) need but that
// would create circular imports if left in declarations.ms or index.ms.
// Extracted to break cycles: expressions↔declarations, statements↔declarations, expressions↔index.

import { Type, TypeKind, Symbol, Node, NodeKind, FunctionDeclData, CallingConvention } from "../../ast/node";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { CGen, CSection, addLine, sec, nameSetHas, nameSetAdd, addCGenError } from "./context";
import { ensureDrcProto, procHeader } from "./types";
import { mangledFunctionName } from "./names";
import { placedInstanceOf } from "../../checker/instantiate";

// ===== DRC forward prototypes =====

// ===== Cross-module function prototypes =====

// On-demand cross-module function prototype emission.
// Called from genCallExpr when a cross-module function is referenced.
export function ensureCrossModuleProto(g: CGen, calleeName: string, fnType: Type, sym: Symbol | null): void {
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
		requestInlineCopy(g, calleeName, placedInstanceOf(sym));
		return;
	}
	if (sym != null && sym.modulePath != "" && sym.modulePath == g.modulePath) return;
	const protoKey = "proto:" + calleeName;
	if (nameSetHas(g.declaredProcs, protoKey)) return;
	nameSetAdd(g.declaredProcs, protoKey);
	const mutBits: int32 = sym != null ? sym.mutatedParams : 0;
	addLine(sec(g, CSection.ProcHeaders), procHeader(g, calleeName, fnType, null, mutBits, false) + ";");
}

export function copiesInline(g: CGen, sym: Symbol): boolean {
	if (sym.symbolType == null || sym.symbolType.callConv != CallingConvention.CcInline) return false;
	if (hasFlag(sym, SymbolFlag.ImportC)) return false;
	return !g.emissionFacts.hcrModules.has(sym.modulePath);
}

export function inlineDeclOf(sym: Symbol): Node | null {
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.FunctionDecl || decl.resolvedSym != sym || decl.nodeType == null) return null;
	if ((decl.data as FunctionDeclData).fnBody == null) return null;
	return decl;
}

function requestInlineCopy(g: CGen, calleeName: string, sym: Symbol): void {
	const key = "inline:" + calleeName;
	if (nameSetHas(g.declaredProcs, key)) return;
	nameSetAdd(g.declaredProcs, key);
	const decl = inlineDeclOf(sym);
	if (decl == null) {
		addCGenError(g, `internal: @inline function '${sym.name}' has no declaration to copy into ${g.modulePath}`, 0, 0);
		return;
	}
	const d = decl.data as FunctionDeclData;
	if (mangledFunctionName(sym, d.fnName, sym.overloadIdx) != calleeName) {
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
import { createCGen, extract } from "./context";

test "a function named like a lifecycle hook keeps the ordinary parameter ABI in its prototype" {
	const num = createPrimitive(TypeKind.Float64);
	const big = createStruct("Big", ["a", "b", "c", "d"], [num, num, num, num], true);
	big.sym = makeSymbol("Big", SymbolKind.Struct, big, false);
	const g = createCGen(null as unknown as CheckerContext, "");
	ensureCrossModuleProto(g, "MakeCopy", createFunction([big], ["p"], num), null);
	assert extract(sec(g, CSection.ProcHeaders)).contains("double MakeCopy(const Big*);");
}
