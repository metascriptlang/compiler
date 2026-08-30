// Type Classification for DRC — determines RC needs and runtime function names
//
// Each type maps to: no-op (primitive), runtime call (string/array/ref/closure),
// or generated lifecycle hook (named Object types from destructorLifting).
//
// The RcInfo result carries enough info to emit the correct AST calls.

import { isPrimitiveKind, isUnresolvedType, hasAsgnFlag, isAwaitable, isAtomicRef, createPrimitive, createStruct, createArray, createFunction, createPtr, createRef, createUnion, createStringLiteral, numberType, stringType, booleanType, voidType, nullType, inferredType, unwrapRefNullUnion, isAllStringLiteralUnion, tupleTypeName, duVariantRegistry, isUnknownType } from "../checker/types";
import { hasFlag, SymbolFlag } from "../checker/symbol";
import { TransformContext, createTransformContext, NameSet, createNameSet, nameSetAdd, nameSetContains } from "../transform/context";
import { NodeKind, Type, TypeKind, TypeFlag, Symbol, SymbolKind } from "../ast/node";
import { canFormAcycle } from "../transform/cycles";
import { mangleMonoName } from "../monomorphize/registry";
import { anonTypeName, isAnonTypeName, arrayCTypeName, hookBaseCName } from "../codegen/c/types";

// ===== RC Classification Kind =====

export enum RcKind {
	None,       // primitive/enum/void — no RC
	String,     // msStringCopy / msStringDecref
	Array,      // msArray* (variant depends on element type)
	Ref,        // msIncref(Cyclic) / msDecref(Cyclic) per canFormAcycle (pointers, interfaces, classes)
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
	// Reference: forallElements recursively calls fillBody per element.
	if (elem.kind === TypeKind.Array) {
		const n = arrayCTypeName(t);
		return makeRcInfo(RcKind.Named, n, n + "Destroy", n + "Copy", n + "WasMoved", n + "Sink", true);
	}
	// Named struct/union elements — use hasAsgnFlag to decide if per-type hooks
	// are needed. Reference parity: fillBody checks tfHasAsgn regardless of
	// kind (Struct/Union/GenericInstance). GenericInstance whose base
	// (typeExtra) is a Struct with fields also qualifies.
	let structElem = elem;
	if (elem.kind === TypeKind.GenericInstance && elem.typeExtra !== null && elem.typeExtra.kind === TypeKind.Struct) {
		structElem = elem.typeExtra;
	}
	const isManaged = (structElem.kind === TypeKind.Struct || structElem.kind === TypeKind.Union)
		&& structElem.typeName !== "";
	if (isManaged) {
		// GenericInstance: typeExtra (base, e.g. Entry<K,V>) inherits abstract-param flags so
		// HasAsgn is absent; the real HasAsgn lives on typeReturn (the instantiated body, fields
		// substituted to concrete). Check both — mirrors the GenericInstance arm in classifyType.
		// Without this, arrays of a mono'd generic struct (Entry__string[]) misclassify as non-RC
		// → no per-element destroy → leak on field-reassign/scope-exit.
		const bodyAsgn = elem.kind === TypeKind.GenericInstance && elem.typeReturn !== null && hasAsgnFlag(elem.typeReturn);
		if (hasAsgnFlag(structElem) || bodyAsgn) {
			// Mangled name for GenericInstance so array hook names match
			// destructorLifting's emitted per-element hooks (unwrapGenericInstance)
			// and codegen's struct name (types.ms:582-588).
			let elemName = "";
			if (elem.kind === TypeKind.GenericInstance) {
				elemName = mangleMonoName(elem.typeName, elem.typeChildren);
			} else {
				elemName = elem.typeName !== "" ? elem.typeName : structElem.typeName;
			}
			const n = elemName + "Array";
			return makeRcInfo(RcKind.Named, n, n + "Destroy", n + "Copy", n + "WasMoved", n + "Sink", true);
		}
		// POD elements: no per-element hooks, but the seq payload is still owned —
		// Nim lifts =destroy/=copy for every tySequence regardless of element
		// triviality (liftdestructors fillSeqOp). The generic macros size the
		// stride from the per-type C array (sizeof data[0]), so they are exact.
		return makeRcInfo(RcKind.Array, "", "msArrayDestroy", "msArrayCopy", "msArrayNumberWasMoved", "msArrayNumberSink", false);
	}
	// Ref/Ptr elements (class arrays) — msRefArray (all pointers are void*)
	// Actor elements are exempt from DRC (managed by actor runtime).
	if (elem.kind === TypeKind.Ref || elem.kind === TypeKind.Ptr) {
		if (elem.sym !== null && elem.sym.symbolKind === SymbolKind.Actor) {
			return makeRcInfo(RcKind.Array, "", "msArrayDestroy", "msArrayCopy", "msArrayNumberWasMoved", "msArrayNumberSink", false);
		}
		// Ref-array elements keep their per-type struct (codegen elemIsRefArray, types.ms:1270)
		// instead of collapsing to msRefArray, so the hooks must match that name.
		if (elem.kind === TypeKind.Ref && elem.typeReturn !== null && elem.typeReturn.kind === TypeKind.Array) {
			const n = arrayCTypeName(t);
			return makeRcInfo(RcKind.Named, n, n + "Destroy", n + "Copy", n + "WasMoved", n + "Sink", true);
		}
		return makeRcInfo(RcKind.Named, "", "msArrayRefDestroy", "msArrayRefCopy", "msArrayRefWasMoved", "msArrayRefCopy", true);
	}
	// Closure element (function type) — msClosureArray stores msClosure structs
	// INLINE (16B stride), NOT as void* pointers. Routing to msArrayRefDestroy
	// would misread struct data as void* → misalignment crash on cleanup
	// (BUG #3). Use the dedicated runtime helper.
	if (elem.kind === TypeKind.Function) {
		return makeRcInfo(RcKind.Named, "", "msArrayClosureDestroy", "msArrayClosureCopy", "msArrayClosureWasMoved", "msArrayClosureSink", true);
	}
	// Distinct nominal wrapper — share underlying type's representation
	// (codegen emits underlying T as the storage). Recurse with the wrapped
	// type so we pick the correct helper for the actual layout. E.g.,
	// `distinct int32` → primitive path → msArrayDestroy (4B stride correct).
	if (elem.kind === TypeKind.Distinct && elem.typeReturn !== null) {
		const unwrapped = createArray(elem.typeReturn);
		return classifyArray(unwrapped, ctx);
	}
	// User-`unknown` elements (opaque handles = Nim seq[pointer], liftdestructors.nim:978
	// tyPointer→defaultOp): entries arrive with NO rc share (classify says inert at every
	// entry site), so hooks must be inert too — counted hooks decref refs the array never
	// received (net −1 per death → UAF, the neon reconcile slab poison). Mirrors the Actor
	// exemption above. `unknown|null` collapses to bare void* (NIM-REF unknown row).
	{
		const bareElem = elem.kind === TypeKind.Union ? unwrapRefNullUnion(elem) : elem;
		if (bareElem !== null && isUnknownType(bareElem)) {
			return makeRcInfo(RcKind.Array, "", "msArrayDestroy", "msArrayCopy", "msArrayNumberWasMoved", "msArrayNumberSink", false);
		}
	}
	// Catch-all assumes void*-stride layout. Correct ONLY when the element
	// is pointer-indirected (which the Ref/Ptr branch above already covers).
	// Any TypeKind reaching this fallthrough with non-pointer layout is the
	// BUG #3 family — msArrayRefDestroy will misread struct data. Future
	// TypeKind additions in element position must add an explicit case
	// above (verify with a runtime cleanup probe before falling through).
	return makeRcInfo(RcKind.Named, "", "msArrayRefDestroy", "msArrayRefCopy", "msArrayRefWasMoved", "msArrayRefCopy", true);
}

// ===== Sub-classifiers for complex arms =====

// Structural-hash view of the DU-variant registry (checker/types stampInlineDuVariants).
// The flag alone misses structurally-equal COPIES (eager per-module imports,
// exploratory literal types) that never pass through createUnion — the hash is
// copy-immune. Lazily ingests new registrations; registry only grows.
let _duHashes: NameSet = null as unknown as NameSet;
let _duHashCursor: number = 0;
function isDuVariantHashName(name: string): boolean {
	if (_duHashes === null) _duHashes = createNameSet();
	const reg = duVariantRegistry();
	while (_duHashCursor < reg.length) {
		nameSetAdd(_duHashes, anonTypeName(reg[_duHashCursor]));
		_duHashCursor = _duHashCursor + 1;
	}
	return nameSetContains(_duHashes, name);
}

function classifyObject(t: Type, ctx: TransformContext): RcInfo {
	// Objects are always value types now — Ref<Object> is handled by TypeKind.Ref arm
	// INLINE union-variant payloads (DuVariant, stamped at createUnion): C storage is
	// the DU machinery's <Union>_vN carrier — msAnon hooks would name a type that
	// doesn't exist in that TU. The machinery owns their lifecycle; defer.
	if ((t.typeFlags & (TypeFlag.DuVariant as int32)) !== 0) return noRcInfo();
	// Anon structs (typeName "" or checker "__anon" pseudo-name) are named msAnon_<hash>
	// by codegen (anonTypeName); destructorLifting's field recursion generates their
	// hooks under that name — resolve identically here (same recipe as fillBody's
	// Struct arm) or anon-struct locals classify as unmanaged: no init copy, no scope
	// destroy, while field stores still release old values (UAF + leak).
	const resolvedName = (t.typeName !== "" && !isAnonTypeName(t.typeName))
		? t.typeName
		: (t.typeNames.length > 0 ? anonTypeName(t) : "");
	if (resolvedName.startsWith("msAnon_") && isDuVariantHashName(resolvedName)) return noRcInfo();
	if (resolvedName !== "") {
		// Reference parity: hasAsgnFlag checks propagated flag (set at type creation)
		if (hasAsgnFlag(t)) {
			const n = hookBaseCName(resolvedName, t, ctx.checkerCtx);
			return makeRcInfo(RcKind.Named, n, n + "Destroy", n + "Copy", n + "WasMoved", n + "Sink", false);
		}
	}
	return noRcInfo();
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
			if (isAtomicRef(t)) return makeRcInfo(RcKind.Ref, "", "msAtomicDecref", "msAtomicIncref", "msPtrWasMoved", "", false);
			// Reference atomicRefOp (liftdestructors.nim:725): cyclic ops — which unregister
			// from the ORC rootset BEFORE the destructor (:748) — only for pointees that can
			// be part of a cycle; plain RC otherwise.
			if (canFormAcycle(t, ctx.cyclicCache, ctx.acyclicCache)) {
				return makeRcInfo(RcKind.Ref, "", "msDecrefCyclic", "msIncrefCyclic", "msPtrWasMoved", "", false);
			}
			return makeRcInfo(RcKind.Ref, "", "msDecref", "msIncref", "msPtrWasMoved", "", false);
		},
		TypeKind.GenericInstance => {
			// Awaitables (`Promise<T>`, plain or affine) are Ref-shaped heap allocs
			// via msAllocTyped — track like any other Ref, same destroyFn. msDecref
			// detects futures via the MS_TYPE_FLAG_FUTURE flag on msFutureTypeInfo
			// (set at allocation by msFutureCreateT) and routes to msFutureDeferredRelease
			// (Amendment H — deferred decref to dispatcher, serializing with the drain
			// decref to eliminate the concurrent-decref race without atomic rc).
			if (isAwaitable(t)) return makeRcInfo(RcKind.Ref, "", "msDecref", "msIncref", "msPtrWasMoved", "", false);
			// Result is a boolean-discriminated match-type Union post-migration —
			// flow through the standard mangled hook generation below.
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
		TypeKind.Ptr | TypeKind.Cursor => {
			// Ptr<T> is always unmanaged — no RC, no lifecycle hooks.
			// Reference parity: cursor fields skip all RC operations.
			return noRcInfo();
		},
		// Closures own a heap env when they capture. needsCleanup=true so a fresh closure value in a
		// Normal (non-consumed) position is captured + destroyed (msClosureDestroy decrefs the env).
		// Two co-requisites make this safe: (1) lambdaLifting sets the closure-pair's nodeType (else
		// the analyzer bails on null), and processObjectLiteral keeps NF_CLOSURE pairs isRefConstr so
		// the env field stays a COPY (the pair owns a counted ref → destroy is balanced, not a
		// double-free with the env-var lifecycle); (2) msClosureDestroy is null-env-safe (core/system.h)
		// so bare-fn closures (env=NULL) no-op, and bare-fn-ref identifiers are skipped in processIdentifier.
		TypeKind.Function => makeRcInfo(RcKind.Closure, "", "msClosureDestroy", "msClosureCopy", "msClosureWasMoved", "msClosureSink", true),
		TypeKind.Struct => classifyObject(t, ctx),
		TypeKind.TypeReference => noRcInfo(),
		TypeKind.Distinct => { if (t.typeReturn !== null) { return classifyType(t.typeReturn, ctx); } else { return noRcInfo(); } },
		TypeKind.Union => {
			// Anonymous nullable-Ref union (`Ref<T> | Null` / `Ptr<T> | Null`):
			// codegen lowers this to a bare T* (see types.ms unwrapRefNullUnion +
			// pointer-size path). DRC must see it as Ref so field assignments emit
			// msIncref and scope cleanup decrefs. Without this, fields typed
			// `T | null` (e.g. `Type.typeReturn`) are not refcounted and dangle
			// when the original allocation is destroyed.
			const refInner = unwrapRefNullUnion(t);
			if (refInner !== null) {
				// Ptr<T> | null shares the bare-pointer C repr with Ref<T> | null,
				// but Ptr is UNMANAGED — incref/decref on a raw pointer (e.g. a
				// C-library allocation with no ms header) corrupts memory.
				if (refInner.kind === TypeKind.Ptr) return noRcInfo();
				// unknown | null: same bare-void* repr; unknown is a non-owning view
				// (Nim parity: `pointer` is RC-inert) and may hold foreign handles.
				if (isUnresolvedType(refInner)) return noRcInfo();
				if (refInner.sym !== null && refInner.sym.symbolKind === SymbolKind.Actor) return noRcInfo();
				if (canFormAcycle(t, ctx.cyclicCache, ctx.acyclicCache)) {
					return makeRcInfo(RcKind.Ref, "", "msDecrefCyclic", "msIncrefCyclic", "msPtrWasMoved", "", false);
				}
				return makeRcInfo(RcKind.Ref, "", "msDecref", "msIncref", "msPtrWasMoved", "", false);
			}
			// Pure string-literal union — msString at runtime (genUnionType), so the
			// String ops apply; the Named path would fabricate <Alias>{Destroy,Copy}
			// hooks for a typedef that never exists.
			if (isAllStringLiteralUnion(t)) {
				return makeRcInfo(RcKind.String, "", "msStringDecref", "msStringCopy", "msStringWasMoved", "msStringSink", false);
			}
			if (t.typeName !== "" && hasAsgnFlag(t)) {
				const un = hookBaseCName(t.typeName, t, ctx.checkerCtx);
				return makeRcInfo(RcKind.Named, un, un + "Destroy", un + "Copy", un + "WasMoved", un + "Sink", false);
			} else { return noRcInfo(); }
		},
		TypeKind.Tuple => {
			// RC tuples get first-class named hooks (destructorLifting ensureTupleHooks); the
			// name MUST be tupleTypeName — the single source codegen + hooks share — so
			// moveOrCopy's msTuple_<hash>{Copy,Destroy} calls resolve.
			let hasRc = false;
			for (const child of t.typeChildren) {
				if (classifyType(child, ctx).needsCleanup) { hasRc = true; }
			}
			if (!hasRc) return noRcInfo();
			const n = tupleTypeName(t);
			return makeRcInfo(RcKind.Named, n, n + "Destroy", n + "Copy", n + "WasMoved", n + "Sink", false);
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
test "Ptr | null → None (raw pointer, never refcounted)" {
	const ctx = createTransformContext();
	const info = classifyType(createUnion([createPtr(voidType()), nullType()]), ctx);
	assert info.rcKind === RcKind.None;
	assert !info.needsCleanup;
}

test "pure strlit union → String ops (msString repr)" {
	const ctx = createTransformContext();
	const u = createUnion([createStringLiteral("column"), createStringLiteral("row")]);
	const info = classifyType(u, ctx);
	assert info.rcKind === RcKind.String;
	assert info.destroyFn === "msStringDecref";
}

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
	const info = classifyType(inferredType(), ctx);
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
	assert info.destroyFn === "msDecrefCyclic";
}

test "ref to self-cyclic struct → cyclic ops" {
	const ctx = createTransformContext();
	const s = createStruct("CycNode", ["next"], [numberType()], false);
	s.typeChildren[0] = createRef(s);
	const info = classifyType(createRef(s), ctx);
	assert info.rcKind === RcKind.Ref;
	assert info.destroyFn === "msDecrefCyclic";
	assert info.copyFn === "msIncrefCyclic";
}

test "ref to leaf struct → plain ops" {
	const ctx = createTransformContext();
	const inner = createStruct("LeafInner", ["value"], [numberType()], false);
	const leaf = createStruct("LeafOuter", ["x", "child"], [numberType(), createRef(inner)], false);
	const info = classifyType(createRef(leaf), ctx);
	assert info.rcKind === RcKind.Ref;
	assert info.destroyFn === "msDecref";
	assert info.copyFn === "msIncref";
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

// DU-variant identity: inline (nameless) union payloads defer to the DU machinery;
// standalone anon structs are owned via msAnon hooks; structurally-equal COPIES of a
// registered variant defer via the structural-hash registry. Distinct field names per
// test — the registry is process-global and keys by structural hash.
test "nameless anon struct with RC field → owned msAnon hooks" {
	const ctx = createTransformContext();
	const info = classifyType(createStruct("", ["solo"], [stringType()], false), ctx);
	assert info.rcKind === RcKind.Named;
	assert info.needsCleanup;
	assert info.typeName.startsWith("msAnon_");
}

test "DuVariant-flagged payload defers to the DU machinery" {
	const ctx = createTransformContext();
	const v = createStruct("", ["vpay"], [stringType()], false);
	createUnion([v, numberType()]);
	assert (v.typeFlags & (TypeFlag.DuVariant as int32)) !== 0;
	const info = classifyType(v, ctx);
	assert !info.needsCleanup;
}

test "structurally-equal copy of a registered variant defers via hash registry" {
	const ctx = createTransformContext();
	const original = createStruct("", ["vpay2"], [stringType()], false);
	createUnion([original, numberType()]);
	const copy = createStruct("", ["vpay2"], [stringType()], false);
	assert (copy.typeFlags & (TypeFlag.DuVariant as int32)) === 0;
	const info = classifyType(copy, ctx);
	assert !info.needsCleanup;
}
