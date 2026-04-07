// C Codegen — Forward Declaration Helpers
//
// Functions that other codegen modules (expressions, statements) need but that
// would create circular imports if left in declarations.ms or index.ms.
// Extracted to break cycles: expressions↔declarations, statements↔declarations, expressions↔index.

import { Type, TypeKind, Symbol } from "../../ast/node";
import { CGen, CSection, addLine, sec, nameSetHas, nameSetAdd, } from "./context";
import { getTypeDesc, isNrvoReturnType, shouldIndirectParam, shouldConstParam } from "./types";

// ===== DRC forward prototypes =====

// DRC lifecycle suffixes — single source of truth for hook detection.
const DRC_SUFFIXES: string[] = ["Destroy", "Copy", "Sink", "WasMoved", "Dup", "Eq", "Trace", "TypeInfo"];

function findSuffix(name: string, suffixes: string[]): string {
	for (const suffix of suffixes) {
		if (name.endsWith(suffix)) return suffix;
	}
	return "";
}

export function isDrcLifecycleName(name: string): boolean {
	if (findSuffix(name, DRC_SUFFIXES) === "") return false;
	// Built-in runtime functions (ms* prefix) are not generated DRC hooks
	if (name.length > 2 && name.byteAt(0) === "m".code && name.byteAt(1) === "s".code) return false;
	// DRC hooks always start with a type name (PascalCase — uppercase first letter).
	// User functions like hasTypeInfo, countHooks start with lowercase — not DRC hooks.
	if (name.length > 0 && name.byteAt(0) >= "a".code && name.byteAt(0) <= "z".code) return false;
	return true;
}

// Emit forward prototype for DRC lifecycle functions called cross-module.
// Signatures are known by convention (suffix determines parameter pattern).
export function ensureDrcProto(g: CGen, callee: string): void {
	if (callee === null || callee === "") return;
	const suffix = findSuffix(callee, DRC_SUFFIXES);
	if (suffix === "") return;
	// Skip built-in runtime functions (ms* prefix) — they're defined in C headers, not generated.
	// Only generate forward declarations for per-type hooks (e.g., TokenDestroy, PointCopy).
	if (callee.length > 2 && callee.byteAt(0) === "m".code && callee.byteAt(1) === "s".code) return;
	if (nameSetHas(g.declaredProcs, callee)) return;
	nameSetAdd(g.declaredProcs, callee);

	// Extract type name prefix: "TypeNameDestroy" → "TypeName"
	const typeName = callee.slice(0, callee.length - suffix.length);
	const isSeqHook = typeName.endsWith("Array");

	const proto = match (suffix) {
		"Destroy" => {
			if (isSeqHook) {
				return `void ${callee}(${typeName} self)`;
			} else {
				return `void ${callee}(${typeName}* self)`;
			}
		},
		"WasMoved" => `void ${callee}(${typeName}* self)`,
		"Copy" | "Sink" => {
			if (isSeqHook) {
				return `void ${callee}(${typeName}* dest, ${typeName} src)`;
			} else {
				return `void ${callee}(${typeName}* dest, ${typeName}* src)`;
			}
		},
		"Dup" => `${typeName} ${callee}(${typeName}* src)`,
		"Eq" => `MS_BOOL ${callee}(${typeName} a, ${typeName} b)`,
		"Trace" => `void ${callee}(${typeName}* self, void* callback)`,
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
