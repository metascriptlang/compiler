// C Codegen — Forward Declaration Helpers
//
// Functions that other codegen modules (expressions, statements) need but that
// would create circular imports if left in declarations.ms or index.ms.
// Extracted to break cycles: expressions↔declarations, statements↔declarations, expressions↔index.

import { Type, TypeKind, Symbol } from "../../ast/node";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { CGen, CSection, addLine, sec, nameSetHas, nameSetAdd, } from "./context";
import { lookupHookSym, ensureDrcProto, procHeader } from "./types";

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
	const suffix = findSuffix(name, DRC_SUFFIXES);
	if (suffix == "") return false;
	// Generated nested value-array walker (msNumberArrayArray, int32_tArrayArray, …) is
	// array-OF-array → base ends "ArrayArray". Always a DRC hook, regardless of prefix/case.
	const drcBase = name.slice(0, name.length - suffix.length);
	if (drcBase.endsWith("ArrayArray")) return true;
	// Ref-array element walker (msUint8Arraystar_Array, int32_tArraystar_Array, …) —
	// the elemIsRefArray per-type struct family; same landmine as the nested walkers.
	if (drcBase.endsWith("star_Array")) return true;
	// Generated tuple hooks are DRC hooks despite the ms prefix; without this the blanket
	// ms→false below would DCE them, leaving an undefined symbol at link.
	if (drcBase.length > 8 && drcBase.slice(0, 8) == "msTuple_") return true;
	// Generated anon-struct hooks (msAnon_<hash>Copy/Sink/…) — same landmine as msTuple_.
	if (drcBase.length > 7 && drcBase.slice(0, 7) == "msAnon_") return true;
	// Other ms* hooks are runtime-provided (single-level array families, msArray, msString…).
	if (name.length > 2 && name.byteAt(0) == "m".code && name.byteAt(1) == "s".code) return false;
	// DRC hooks otherwise start with a type name (PascalCase). User functions like
	// hasTypeInfo, countHooks start with lowercase — not DRC hooks.
	if (name.length > 0 && name.byteAt(0) >= "a".code && name.byteAt(0) <= "z".code) return false;
	return true;
}

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
	const hook = sym != null ? sym : lookupHookSym(calleeName);
	if (hook != null && hasFlag(hook, SymbolFlag.GeneratedOp)) {
		ensureDrcProto(g, calleeName, hook);
		return;
	}
	if (sym != null && sym.modulePath != "" && sym.modulePath == g.modulePath) return;
	const protoKey = "proto:" + calleeName;
	if (nameSetHas(g.declaredProcs, protoKey)) return;
	nameSetAdd(g.declaredProcs, protoKey);
	const mutBits: int32 = sym != null ? sym.mutatedParams : 0;
	addLine(sec(g, CSection.ProcHeaders), procHeader(g, calleeName, fnType, null, mutBits, isDrcLifecycleName(calleeName)) + ";");
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
