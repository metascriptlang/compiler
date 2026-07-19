// C Codegen — Forward Declaration Helpers
//
// Functions that other codegen modules (expressions, statements) need but that
// would create circular imports if left in declarations.ms or index.ms.
// Extracted to break cycles: expressions↔declarations, statements↔declarations, expressions↔index.

import { Type, TypeKind, Symbol } from "../../ast/node";
import { CGen, CSection, addLine, sec, nameSetHas, nameSetAdd, } from "./context";
import { getTypeDesc, isNrvoReturnType, shouldIndirectParam, shouldConstParam } from "./types";
import { findExportedSymbol } from "../../checker/context";

// ===== DRC forward prototypes =====

// DRC lifecycle suffixes — single source of truth for hook detection.
const DRC_SUFFIXES: string[] = ["Destroy", "Copy", "Sink", "WasMoved", "Dup", "Eq", "Trace", "TypeInfo"];

function findSuffix(name: string, suffixes: string[]): string {
	for (const suffix of suffixes) {
		if (name.endsWith(suffix)) return suffix;
	}
	return "";
}

// A generated DRC hook whose mangled name starts with "ms" — i.e. a per-type NESTED
// value-array walker (msNumberArrayArrayDestroy, msStringArrayArrayDestroy, …). These
// collide by prefix with the runtime-provided ms* hooks, so distinguish by the CLOSED
// runtime base set, never by the prefix alone.
function isGeneratedMsArrayHook(name: string): boolean {
	if (!(name.length > 2 && name.byteAt(0) === "m".code && name.byteAt(1) === "s".code)) return false;
	const suffix = findSuffix(name, DRC_SUFFIXES);
	if (suffix === "") return false;
	const base = name.slice(0, name.length - suffix.length);
	// Runtime ms* array hooks are all single-level (msArray, msNumberArray, msStringArray,
	// msRefArray, msUint8Array, msClosureArray); a generated nested value-array walker is
	// array-OF-array, so its base ends in "ArrayArray". That alone discriminates — no denylist.
	return base.endsWith("ArrayArray");
}

// Generated tuple hook (msTuple_<hash>{Destroy,Copy,Sink,WasMoved}) for a structural tuple.
// Runtime ms* families never carry a "_<hash>" segment, so the msTuple_ base discriminates.
function isGeneratedMsTupleHook(name: string): boolean {
	if (!(name.length > 2 && name.byteAt(0) === "m".code && name.byteAt(1) === "s".code)) return false;
	const suffix = findSuffix(name, DRC_SUFFIXES);
	if (suffix === "") return false;
	const base = name.slice(0, name.length - suffix.length);
	return base.length > 8 && base.slice(0, 8) === "msTuple_";
}

// Generated anon-struct hook (msAnon_<hash>{Destroy,Copy,Sink,WasMoved}) — same
// discrimination as msTuple_: runtime ms* families never carry a "_<hash>" segment.
function isGeneratedMsAnonHook(name: string): boolean {
	if (!(name.length > 2 && name.byteAt(0) === "m".code && name.byteAt(1) === "s".code)) return false;
	const suffix = findSuffix(name, DRC_SUFFIXES);
	if (suffix === "") return false;
	const base = name.slice(0, name.length - suffix.length);
	return base.length > 7 && base.slice(0, 7) === "msAnon_";
}

export function isDrcLifecycleName(name: string): boolean {
	const suffix = findSuffix(name, DRC_SUFFIXES);
	if (suffix === "") return false;
	// Generated nested value-array walker (msNumberArrayArray, int32_tArrayArray, …) is
	// array-OF-array → base ends "ArrayArray". Always a DRC hook, regardless of prefix/case.
	const drcBase = name.slice(0, name.length - suffix.length);
	if (drcBase.endsWith("ArrayArray")) return true;
	// Generated tuple hooks are DRC hooks despite the ms prefix; without this the blanket
	// ms→false below would DCE them, leaving an undefined symbol at link.
	if (drcBase.length > 8 && drcBase.slice(0, 8) === "msTuple_") return true;
	// Generated anon-struct hooks (msAnon_<hash>Copy/Sink/…) — same landmine as msTuple_.
	if (drcBase.length > 7 && drcBase.slice(0, 7) === "msAnon_") return true;
	// Other ms* hooks are runtime-provided (single-level array families, msArray, msString…).
	if (name.length > 2 && name.byteAt(0) === "m".code && name.byteAt(1) === "s".code) return false;
	// DRC hooks otherwise start with a type name (PascalCase). User functions like
	// hasTypeInfo, countHooks start with lowercase — not DRC hooks.
	if (name.length > 0 && name.byteAt(0) >= "a".code && name.byteAt(0) <= "z".code) return false;
	return true;
}

// Emit forward prototype for DRC lifecycle functions called cross-module.
// Signatures are known by convention (suffix determines parameter pattern).
export function ensureDrcProto(g: CGen, callee: string): void {
	if (callee === null || callee === "") return;
	const suffix = findSuffix(callee, DRC_SUFFIXES);
	if (suffix === "") return;
	// Skip built-in runtime ms* hooks (defined in C headers) — but NOT generated nested
	// value-array walkers (msNumberArrayArrayDestroy …) or tuple hooks (msTuple_<hash>Destroy …),
	// which are emitted by destructorLifting and need a forward proto.
	if (callee.length > 2 && callee.byteAt(0) === "m".code && callee.byteAt(1) === "s".code
		&& !isGeneratedMsArrayHook(callee) && !isGeneratedMsTupleHook(callee)
		&& !isGeneratedMsAnonHook(callee)) return;
	if (nameSetHas(g.declaredProcs, callee)) return;
	nameSetAdd(g.declaredProcs, callee);

	// Extract type name prefix: "TypeNameDestroy" → "TypeName"
	const typeName = callee.slice(0, callee.length - suffix.length);
	// Anon-struct hooks: the full typedef block only exists in TUs where
	// getTypeDesc ran for the type — a consumer TU referencing just the hook
	// needs an opaque forward so `msAnon_X*` in the proto is a known type
	// (identical typedef redeclaration is legal C11).
	if (isGeneratedMsAnonHook(callee)) {
		addLine(sec(g, CSection.ProcHeaders), `typedef struct ${typeName} ${typeName};`);
	}
	const isSeqHook = typeName.endsWith("Array");

	const proto = match (suffix) {
		"Destroy" => `void ${callee}(${typeName}* self)`,
		"WasMoved" => `void ${callee}(${typeName}* self)`,
		"Copy" | "Sink" => `void ${callee}(${typeName}* dest, ${typeName}* src)`,
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
	// Recovery path: re-exported symbols imported via a hub module (e.g.,
	// `export { X } from "./source"`) can end up with Unknown symbolType in the
	// caller's scope when the hub's collectExport runs before the source module's
	// Phase 2 resolve completes. Look up the canonical type from the source
	// module's registry entry — by this point (codegen), all modules have been
	// type-checked and the registry holds resolved types.
	if ((fnType === null || fnType.kind !== TypeKind.Function)
			&& sym !== null && sym.modulePath !== ""
			&& g.checkerCtx !== null && g.checkerCtx.exportRegistry !== null) {
		const lookupName = sym.originalName !== "" ? sym.originalName : sym.name;
		const info = findExportedSymbol(g.checkerCtx.exportRegistry, sym.modulePath, lookupName);
		if (info !== null && info.symType !== null && info.symType.kind === TypeKind.Function) {
			fnType = info.symType;
		}
	}
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

// ms-prefixed GENERATED hooks must classify as DRC hooks or isDeclAlive DCEs their
// defs (undefined symbol at link once a call site is reachable) — msTuple_ and
// msAnon_ both hit the blanket ms→false landmine.
test "generated tuple and anon hooks are DRC hooks despite ms prefix" {
	assert isDrcLifecycleName("msTuple_lta21pDestroy");
	assert isDrcLifecycleName("msAnon_7qcfd4Copy");
	assert isDrcLifecycleName("msAnon_7qcfd4Sink");
	assert isDrcLifecycleName("msAnon_7qcfd4Dup");
	assert !isDrcLifecycleName("msArrayCopy");
	assert !isDrcLifecycleName("msStringCopy");
}
