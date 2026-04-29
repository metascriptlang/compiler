// Type Classification for DRC — determines RC needs and runtime function names
//
// Each type maps to: no-op (primitive), runtime call (string/array/ref/closure),
// or generated lifecycle hook (named Object types from destructorLifting).
//
// The RcInfo result carries enough info to emit the correct AST calls.

import { isPrimitiveKind, hasAsgnFlag, isAwaitable, isResult, createPrimitive, createStruct, createArray, createFunction, createPtr, numberType, stringType, booleanType, voidType, nullType, unknownType } from "../checker/types";
import { hasFlag, SymbolFlag } from "../checker/symbol";
import { TransformContext, createTransformContext } from "../transform/context";
import { NodeKind, Type, TypeKind, Symbol, SymbolKind } from "../ast/node";
import { mangleMonoName } from "../monomorphize/registry";

// ===== RC Classification Kind =====

export enum RcKind {
	None,       // primitive/enum/void — no RC
	String,     // msStringCopy / msStringDecref
	Array,      // msArray* (variant depends on element type)
	Ref,        // msIncref / msDecref (pointers, interfaces, classes)
	Closure,    // msClosure*
	Named,      // TypeName_destroy / TypeName_copy (from destructorLifting)
}

// ===== RC Info — complete description of a type's RC operations =====

export interface RcInfo {
	rcKind: RcKind;
	typeName: string;        // "Token", "Node" etc. Empty for builtins.
	needsCleanup: boolean;   // true if scope-exit destroy is needed
	destroyFn: string;       // runtime function name for =destroy
	copyFn: string;          // runtime function name for =copy
	wasMovedFn: string;      // runtime function name for =wasMoved
	sinkFn: string;          // runtime function name for =sink (empty = raw assign)
	seqLike: boolean;        // reference parity: sequence/string destroy by-value, copy src by-value
}

// ===== Sentinel — no RC needed =====

export function noRcInfo(): RcInfo {
	return {
		rcKind: RcKind.None,
		typeName: "",
		needsCleanup: false,
		destroyFn: "",
		copyFn: "",
		wasMovedFn: "",
		sinkFn: "",
		seqLike: false,
	};
}

// ===== RC Info Factory — reduces verbose inline literals =====

function makeRcInfo(kind: RcKind, typeName: string, destroy: string, copy: string, wasMoved: string, sink: string, seqLike: boolean): RcInfo {
	return { rcKind: kind, typeName, needsCleanup: true, destroyFn: destroy, copyFn: copy, wasMovedFn: wasMoved, sinkFn: sink, seqLike };
}

// ===== Array Subclassification =====
// Reference parity: use hasAsgnFlag (propagated at type creation) instead of runtime element inspection.

function classifyArray(t: Type, ctx: TransformContext): RcInfo {
	const elem = t.typeReturn;
	if (elem !== null && elem.kind === TypeKind.Uint8) {
		return makeRcInfo(RcKind.Array, "", "msArrayUint8Destroy", "msArrayUint8Copy", "msArrayUint8WasMoved", "msArrayUint8Sink", false);
	}
	if (elem === null || isPrimitiveKind(elem.kind)) {
		return makeRcInfo(RcKind.Array, "", "msArrayDestroy", "msArrayCopy", "msArrayNumberWasMoved", "msArrayNumberSink", false);
	}
	if (elem.kind === TypeKind.String) {
		return makeRcInfo(RcKind.Named, "", "msArrayStringDestroy", "msArrayStringCopy", "msArrayStringWasMoved", "msArrayStringSink", true);
	}
	// Nested array elements (e.g. string[][]) — inner arrays are value-type structs.
	// Reference: forallElements recursively calls fillBody per element. We use generic array ops
	// as safe default (frees outer payload). Follow-up: per-type hooks in destructorLifting.
	if (elem.kind === TypeKind.Array) {
		return makeRcInfo(RcKind.Array, "", "msArrayDestroy", "msArrayCopy", "msArrayNumberWasMoved", "msArrayNumberSink", false);
	}
	// Named struct elements — use hasAsgnFlag to decide if per-type hooks are needed.
	// Reference parity: fillBody checks tfHasAsgn regardless of type kind (Struct or GenericInstance).
	// GenericInstance whose base (typeExtra) is a Struct with fields also qualifies.
	let structElem = elem;
	if (elem.kind === TypeKind.GenericInstance && elem.typeExtra !== null && elem.typeExtra.kind === TypeKind.Struct) {
		structElem = elem.typeExtra;
	}
	if ((structElem.kind === TypeKind.Struct) && structElem.typeName !== "") {
		if (hasAsgnFlag(structElem)) {
			// Use mangled name for GenericInstance elements so array hook names match
			// destructorLifting's emitted per-element hooks (unwrapGenericInstance) and
			// codegen's struct name (types.ms:582-588).
			let elemName = "";
			if (elem.kind === TypeKind.GenericInstance) {
				elemName = mangleMonoName(elem.typeName, elem.typeChildren);
			} else {
				elemName = elem.typeName !== "" ? elem.typeName : structElem.typeName;
			}
			const n = elemName + "Array";
			return makeRcInfo(RcKind.Named, n, n + "Destroy", n + "Copy", n + "WasMoved", n + "Sink", true);
		}
		return noRcInfo();
	}
	// Ref/Ptr elements (class arrays) — msRefArray (all pointers are void*)
	// Actor elements are exempt from DRC (managed by actor runtime).
	if (elem.kind === TypeKind.Ref || elem.kind === TypeKind.Ptr) {
		if (elem.sym !== null && elem.sym.symbolKind === SymbolKind.Actor) {
			return makeRcInfo(RcKind.Array, "", "msArrayDestroy", "msArrayCopy", "msArrayNumberWasMoved", "msArrayNumberSink", false);
		}
		return makeRcInfo(RcKind.Named, "", "msArrayRefDestroy", "msArrayRefCopy", "msArrayRefWasMoved", "msArrayRefCopy", true);
	}
	// Default: ref array for unknown element types (conservative safe fallback)
	return makeRcInfo(RcKind.Named, "", "msArrayRefDestroy", "msArrayRefCopy", "msArrayRefWasMoved", "msArrayRefCopy", true);
}

// ===== Sub-classifiers for complex arms =====

function classifyObject(t: Type, ctx: TransformContext): RcInfo {
	// Objects are always value types now — Ref<Object> is handled by TypeKind.Ref arm
	if (t.typeName !== "") {
		// Reference parity: hasAsgnFlag checks propagated flag (set at type creation)
		if (hasAsgnFlag(t)) {
			return makeRcInfo(RcKind.Named, t.typeName, t.typeName + "Destroy", t.typeName + "Copy", t.typeName + "WasMoved", t.typeName + "Sink", false);
		}
		return noRcInfo();
	}
	return noRcInfo();
}

// ===== Ownership Helpers =====

export function isSinkParam(sym: Symbol): boolean {
	if (sym === null) return false;
	return hasFlag(sym, SymbolFlag.Sink);
}

export function isLentParam(sym: Symbol): boolean {
	if (sym === null) return false;
	return hasFlag(sym, SymbolFlag.Lent);
}

// ===== Main Classification Entry Point =====

export function classifyType(t: Type | null, ctx: TransformContext): RcInfo {
	if (t === null) return noRcInfo();
	if (isPrimitiveKind(t.kind)) return noRcInfo();

	return match (t.kind) {
		TypeKind.String => makeRcInfo(RcKind.String, "", "msStringDecref", "msStringCopy", "msStringWasMoved", "msStringSink", false),
		TypeKind.Array => classifyArray(t, ctx),
		TypeKind.Ref => {
			// Actors are exempt from DRC — their lifecycle is managed by the actor
			// runtime (mailbox processing, supervision, ORCA-style collection).
			// DRC scope cleanup would null actor pointers in arrays/variables while
			// messages are still in flight. Pony parity: actors are never GC'd while
			// reachable; Malebolgia parity: concurrency primitives bypass GC entirely.
			if (t.sym !== null && t.sym.symbolKind === SymbolKind.Actor) return noRcInfo();
			return makeRcInfo(RcKind.Ref, "", "msDecref", "msIncref", "msPtrWasMoved", "", false);
		},
		TypeKind.GenericInstance => {
			// Awaitables (`Promise<T>`, plain or affine) are exempt from DRC — their lifecycle
			// is managed by the await transform (create → wait → explicit destroy).
			if (isAwaitable(t)) return noRcInfo();
			// Result has bespoke codegen (msResult_<ok>_<err> — codegen/types.ms:1083).
			// destructorLifting also skips these; using mangleMonoName here would produce
			// hook names pointing to a type codegen never emits → link error.
			if (isResult(t)) return noRcInfo();
			// Monomorphized struct instance: build hook names via `mangleMonoName` so they match
			// codegen's struct naming (src/codegen/c/types.ms:582-588) and destructorLifting's
			// hook emission (unwrapGenericInstance).
			//
			// hasAsgn check: the GenericInstance wrapper's typeFlags inherit from the generic
			// BASE (e.g. `Entry<K,V>`) where K/V are GenericParam (no hasAsgn). Only after
			// `instantiateGenericBody` populates `typeReturn` with concrete fields do we know
			// whether the substituted body has managed fields. Check both the wrapper AND the
			// instantiated body.
			if (t.typeName !== "") {
				const bodyHasAsgn = t.typeReturn !== null && hasAsgnFlag(t.typeReturn);
				if (hasAsgnFlag(t) || bodyHasAsgn) {
					const mangled = mangleMonoName(t.typeName, t.typeChildren);
					return makeRcInfo(RcKind.Named, mangled, mangled + "Destroy", mangled + "Copy", mangled + "WasMoved", mangled + "Sink", false);
				}
			}
			return noRcInfo();
		},
		TypeKind.Ptr => {
			// Ptr<T> is always unmanaged — no RC, no lifecycle hooks.
			// Reference parity: cursor fields skip all RC operations.
			return noRcInfo();
		},
		TypeKind.Function => makeRcInfo(RcKind.Closure, "", "msClosureDestroy", "msClosureCopy", "msClosureWasMoved", "msClosureSink", false),
		TypeKind.Struct => classifyObject(t, ctx),
		TypeKind.TypeReference => noRcInfo(),
		TypeKind.Distinct => { if (t.typeReturn !== null) { return classifyType(t.typeReturn, ctx); } else { return noRcInfo(); } },
		TypeKind.Union => {
			if (t.typeName !== "" && hasAsgnFlag(t)) {
				return makeRcInfo(RcKind.Named, t.typeName, t.typeName + "Destroy", t.typeName + "Copy", t.typeName + "WasMoved", t.typeName + "Sink", false);
			} else { return noRcInfo(); }
		},
		TypeKind.Tuple => {
			// Check if any element needs RC
			let hasRc = false;
			for (const child of t.typeChildren) {
				if (classifyType(child, ctx).needsCleanup) { hasRc = true; }
			}
			// TODO: Tuples with RC elements need per-field hooks from destructorLifting.
			// For now, emit Named with empty hooks — helper functions guard against empty fnName.
			if (hasRc) { return makeRcInfo(RcKind.Named, "", "", "", "", "", false); } else { return noRcInfo(); }
		},
		_ => noRcInfo(),
	};
}

// ===== Fresh Expression Detection =====
// Fresh expressions produce owned values — no copy needed on init.

export function isFreshExpr(kind: NodeKind): boolean {
	return match (kind) {
		NodeKind.CallExpr | NodeKind.NewExpr
		| NodeKind.ObjectLiteral | NodeKind.ArrayLiteral
		| NodeKind.StringLiteral | NodeKind.NumberLiteral
		| NodeKind.BooleanLiteral | NodeKind.NullLiteral
		| NodeKind.ArrowFunction | NodeKind.FunctionExpr
		| NodeKind.MoveExpr | NodeKind.ConditionalExpr => true,
		_ => false,
	};
}

// ===== Tests =====
test "number → None" {
	const ctx = createTransformContext();
	const info = classifyType(numberType(), ctx);
	assert info.rcKind === RcKind.None;
	assert !info.needsCleanup;
}

test "boolean → None" {
	const ctx = createTransformContext();
	const info = classifyType(booleanType(), ctx);
	assert info.rcKind === RcKind.None;
}

test "void → None" {
	const ctx = createTransformContext();
	const info = classifyType(voidType(), ctx);
	assert info.rcKind === RcKind.None;
}

test "null → None" {
	const ctx = createTransformContext();
	const info = classifyType(nullType(), ctx);
	assert info.rcKind === RcKind.None;
}

test "unknown → None" {
	const ctx = createTransformContext();
	const info = classifyType(unknownType(), ctx);
	assert info.rcKind === RcKind.None;
}

test "int32 → None" {
	const ctx = createTransformContext();
	const info = classifyType(createPrimitive(TypeKind.Int32), ctx);
	assert info.rcKind === RcKind.None;
}

test "enum → None" {
	const ctx = createTransformContext();
	const info = classifyType(createPrimitive(TypeKind.Enum), ctx);
	assert info.rcKind === RcKind.None;
}

test "null type input → None" {
	const ctx = createTransformContext();
	const info = classifyType(null, ctx);
	assert info.rcKind === RcKind.None;
}

test "string → String" {
	const ctx = createTransformContext();
	const info = classifyType(stringType(), ctx);
	assert info.rcKind === RcKind.String;
	assert info.needsCleanup;
	assert info.destroyFn === "msStringDecref";
	assert info.copyFn === "msStringCopy";
	assert info.wasMovedFn === "msStringWasMoved";
}

test "array of number → Array" {
	const ctx = createTransformContext();
	const info = classifyType(createArray(numberType()), ctx);
	assert info.rcKind === RcKind.Array;
	assert info.needsCleanup;
	assert info.destroyFn === "msArrayDestroy";
}

test "array of string → Named (standalone procs)" {
	const ctx = createTransformContext();
	const info = classifyType(createArray(stringType()), ctx);
	assert info.rcKind === RcKind.Named;
	assert info.seqLike;
	assert info.destroyFn === "msArrayStringDestroy";
}

test "function → Closure" {
	const ctx = createTransformContext();
	const info = classifyType(createFunction([], [], voidType()), ctx);
	assert info.rcKind === RcKind.Closure;
	assert info.needsCleanup;
	assert info.destroyFn === "msClosureDestroy";
}

test "named object with managed field → Named" {
	const ctx = createTransformContext();
	const info = classifyType(createStruct("Token", ["value"], [stringType()], false), ctx);
	assert info.rcKind === RcKind.Named;
	assert info.needsCleanup;
	assert info.destroyFn === "TokenDestroy";
	assert info.copyFn === "TokenCopy";
	assert info.wasMovedFn === "TokenWasMoved";
}

test "named object without managed field → noRcInfo" {
	const ctx = createTransformContext();
	const info = classifyType(createStruct("Point", ["x", "y"], [numberType(), numberType()], false), ctx);
	assert !info.needsCleanup;
}

test "anonymous object → None" {
	const ctx = createTransformContext();
	const info = classifyType(createStruct("", ["x"], [numberType()], false), ctx);
	assert info.rcKind === RcKind.None;
}

test "ref → Ref" {
	const ctx = createTransformContext();
	const t = createPrimitive(TypeKind.Ref);
	const info = classifyType(t, ctx);
	assert info.rcKind === RcKind.Ref;
	assert info.destroyFn === "msDecref";
}

test "ptr → None (unmanaged)" {
	const ctx = createTransformContext();
	const info = classifyType(createPtr(stringType()), ctx);
	assert info.rcKind === RcKind.None;
	assert !info.needsCleanup;
}

test "call is fresh" { assert isFreshExpr(NodeKind.CallExpr); }

test "new is fresh" { assert isFreshExpr(NodeKind.NewExpr); }

test "object literal is fresh" { assert isFreshExpr(NodeKind.ObjectLiteral); }

test "string literal is fresh" { assert isFreshExpr(NodeKind.StringLiteral); }

test "identifier is NOT fresh" { assert !isFreshExpr(NodeKind.Identifier); }

test "member access is NOT fresh" { assert !isFreshExpr(NodeKind.MemberExpr); }

test "binary expr is NOT fresh" { assert !isFreshExpr(NodeKind.BinaryExpr); }
