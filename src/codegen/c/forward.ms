// C Codegen — Forward Declaration Helpers
//
// Functions that other codegen modules (expressions, statements) need but that
// would create circular imports if left in declarations.ms or index.ms.
// Extracted to break cycles: expressions↔declarations, statements↔declarations, expressions↔index.

import { Type, TypeKind, Symbol } from "../../ast/node";
import {
	CGen, CSection,
	addLine, sec, nameSetHas, nameSetAdd,
} from "./context";
import { getTypeDesc, isNrvoReturnType, ccgIntroducedPtr, shouldIndirectParam, shouldConstParam } from "./types";

// ===== DRC forward prototypes =====

// DRC lifecycle suffixes — single source of truth for hook detection.
const DRC_SUFFIXES: string[] = ["_destroy", "_copy", "_sink", "_wasMoved", "_dup", "_eq", "_trace", "_typeInfo"];

function hasSuffix(name: string, suffixes: string[]): boolean {
	for (const suffix of suffixes) {
		if (name.endsWith(suffix)) return true;
	}
	return false;
}

export function isDrcLifecycleName(name: string): boolean {
	return hasSuffix(name, DRC_SUFFIXES);
}

// Emit forward prototype for DRC lifecycle functions called cross-module.
// Signatures are known by convention (suffix determines parameter pattern).
export function ensureDrcProto(g: CGen, callee: string): void {
	if (!isDrcLifecycleName(callee)) return;
	if (nameSetHas(g.declaredProcs, callee)) return;
	nameSetAdd(g.declaredProcs, callee);

	// Extract type name prefix: "TypeName_destroy" → "TypeName"
	const lastUnderscore = callee.lastIndexOf("_");
	if (lastUnderscore < 0) return;
	const typeName = callee.slice(0, lastUnderscore);
	const suffix = callee.slice(lastUnderscore, callee.length);

	const isSeqHook = typeName.endsWith("Array");

	const proto = match (suffix) {
		"_destroy" => {
			if (isSeqHook) {
				return `void ${callee}(${typeName} self)`;
			} else {
				return `void ${callee}(${typeName}* self)`;
			}
		},
		"_wasMoved" => `void ${callee}(${typeName}* self)`,
		"_copy" | "_sink" => {
			if (isSeqHook) {
				return `void ${callee}(${typeName}* dest, ${typeName} src)`;
			} else {
				return `void ${callee}(${typeName}* dest, ${typeName}* src)`;
			}
		},
		"_dup" => `${typeName} ${callee}(${typeName}* src)`,
		"_eq" => `MS_BOOL ${callee}(${typeName} a, ${typeName} b)`,
		"_trace" => `void ${callee}(${typeName}* self, void* callback)`,
		_ => { return; },
	};
	addLine(sec(g, CSection.ProcHeaders), proto + ";");
}

// ===== Cross-module function prototypes =====

// On-demand cross-module function prototype emission.
// Called from genCallExpr when a cross-module function is referenced.
export function ensureCrossModuleProto(g: CGen, calleeName: string, fnType: Type, sym: Symbol): void {
	if (fnType === null || fnType.kind !== TypeKind.Function) return;
	// DRC hooks: use ensureDrcProto instead (correct fixed-convention signatures)
	if (isDrcLifecycleName(calleeName)) {
		ensureDrcProto(g, calleeName);
		return;
	}
	if (sym !== null && sym.modulePath !== "" && sym.modulePath === g.modulePath) return;
	const protoKey = "proto:" + calleeName;
	if (nameSetHas(g.declaredProcs, protoKey)) return;
	nameSetAdd(g.declaredProcs, protoKey);
	const retType = getTypeDesc(g, fnType.typeReturn);
	const nrvo = isNrvoReturnType(fnType.typeReturn, fnType);
	let paramList = "";
	if (nrvo) {
		paramList = retType + "* __result";
		if (fnType.typeChildren !== null && fnType.typeChildren.length > 0) paramList = paramList + ", ";
	}
	if (fnType.typeChildren !== null) {
		const fwdMutBits: int32 = sym !== null ? sym.mutatedParams : 0;
		let i = 0;
		while (i < fnType.typeChildren.length) {
			if (i > 0) paramList = paramList + ", ";
			let pType = getTypeDesc(g, fnType.typeChildren[i]);
			const fwdMut = (fwdMutBits & (1 << (i as int32))) !== 0;
			if (shouldIndirectParam(fnType.typeChildren[i], fwdMut) && pType.byteLength > 0 && pType.charAt(pType.byteLength as int64 - 1) !== "*") {
				pType = shouldConstParam(fnType.typeChildren[i], fwdMut) ? "const " + pType + "*" : pType + "*";
			}
			paramList = paramList + pType;
			i += 1;
		}
	}
	if (paramList === "") paramList = "void";
	let cRetType = retType;
	if (nrvo) cRetType = "void";
	addLine(sec(g, CSection.ProcHeaders), `${cRetType} ${calleeName}(${paramList});`);
}

// useHeader + emitIncludeDirectives moved to context.ms to break types.ms ↔ forward.ms cycle.
