// Type Classification for DRC — determines RC needs and runtime function names
//
// Each type maps to: no-op (primitive), runtime call (string/array/ref/closure/map/set),
// or generated lifecycle hook (named Object types from destructorLifting).
//
// The RcInfo result carries enough info to emit the correct AST calls.

import { Type, TypeKind, isPrimitiveKind, hasDestructor, isInterfaceType, createPrimitive, createObject, createArray, createFunction, numberType, stringType, booleanType, voidType, nullType, unknownType } from "../checker/types";
import { lookupSymbol, SymbolKind, isPointerType as isPointerTypeBase, Symbol, hasFlag, SymbolFlag } from "../checker/symbol";
import { TransformContext, createTransformContext } from "../transform/context";
import { NodeKind } from "../ast/node";

// ===== RC Classification Kind =====

export enum RcKind {
	None,       // primitive/enum/void — no RC
	String,     // msStringIncref / msStringDecref
	Array,      // msArray* (variant depends on element type)
	Ref,        // msIncref / msDecref (pointers, interfaces, classes)
	Closure,    // msClosure*
	Map,        // msMap*
	Set,        // msSet*
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
	};
}

// ===== RC Info Factory — reduces verbose inline literals =====

function makeRcInfo(kind: RcKind, typeName: string, destroy: string, copy: string, wasMoved: string, sink: string): RcInfo {
	return { rcKind: kind, typeName, needsCleanup: true, destroyFn: destroy, copyFn: copy, wasMovedFn: wasMoved, sinkFn: sink };
}

// ===== Pointer Type Wrapper (adapts SymbolTable-based helper to TransformContext) =====

function isPointerType(t: Type, ctx: TransformContext): boolean {
	if (ctx.checkerCtx === null) return false;
	return isPointerTypeBase(t, ctx.checkerCtx.table);
}

// ===== Array Subclassification =====

function classifyArray(t: Type, ctx: TransformContext): RcInfo {
	const elem = t.typeReturn;  // Array element type stored in typeReturn
	if (elem !== null && elem.kind === TypeKind.Uint8) {
		return makeRcInfo(RcKind.Array, "", "msArrayUint8Destroy", "msArrayUint8Copy", "msArrayUint8WasMoved", "msArrayUint8Sink");
	}
	if (elem === null || isPrimitiveKind(elem.kind)) {
		return makeRcInfo(RcKind.Array, "", "msArrayDestroy", "msArrayCopy", "msArrayNumberWasMoved", "msArrayNumberSink");
	}
	if (elem.kind === TypeKind.String) {
		return makeRcInfo(RcKind.Array, "", "msArrayStringDestroy", "msArrayStringCopy", "msArrayStringWasMoved", "msArrayStringSink");
	}
	return makeRcInfo(RcKind.Array, "", "msArrayRefDestroy", "msArrayRefCopy", "msArrayRefWasMoved", "msArrayRefCopy");
}

// ===== Sub-classifiers for complex arms =====

function classifyObject(t: Type, ctx: TransformContext): RcInfo {
	if (isPointerType(t, ctx)) {
		return makeRcInfo(RcKind.Ref, t.typeName, "msDecref", "msIncref", "msPtrWasMoved", "");
	}
	if (t.typeName !== "") {
		// Implementation parity: only generate RC hooks if type has a destructor
		// Value-type interfaces without managed fields get noRcInfo (no cleanup needed)
		if (hasDestructor(t)) {
			return makeRcInfo(RcKind.Named, t.typeName, t.typeName + "_destroy", t.typeName + "_copy", t.typeName + "_wasMoved", t.typeName + "_sink");
		}
		// destructorLifting has already run — if no hooks, type is plain value (no cleanup)
		return noRcInfo();
	}
	return noRcInfo();
}

function classifyTypeRef(t: Type, ctx: TransformContext): RcInfo {
	if (t.typeName === "" || ctx.checkerCtx === null) return noRcInfo();
	const sym = lookupSymbol(ctx.checkerCtx.table, t.typeName);
	if (sym === null) return noRcInfo();
	return classifyType(sym.symbolType, ctx);
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

export function classifyType(t: Type, ctx: TransformContext): RcInfo {
	if (t === null) return noRcInfo();
	if (isPrimitiveKind(t.kind)) return noRcInfo();

	return match (t.kind) {
		TypeKind.String => makeRcInfo(RcKind.String, "", "msStringDecref", "msStringIncref", "msStringWasMoved", "msStringSink"),
		TypeKind.Array => classifyArray(t, ctx),
		TypeKind.Ref => makeRcInfo(RcKind.Ref, "", "msDecref", "msIncref", "msPtrWasMoved", ""),
		TypeKind.Ptr => {
			// Ptr<T> where T is interface/span/result/tuple = borrowed (ccgIntroducedPtr), no RC
			const inner = t.typeReturn;
			if (inner !== null && (isInterfaceType(inner) || inner.kind === TypeKind.Span || inner.kind === TypeKind.Result || inner.kind === TypeKind.Tuple)) {
				noRcInfo()
			} else {
				makeRcInfo(RcKind.Ref, "", "msDecref", "msIncref", "msPtrWasMoved", "")
			}
		},
		TypeKind.Function => makeRcInfo(RcKind.Closure, "", "msClosureDestroy", "msClosureCopy", "msClosureWasMoved", "msClosureSink"),
		TypeKind.Map => makeRcInfo(RcKind.Map, "", "msMapFree", "msMapCopy", "msMapWasMoved", "msMapSink"),
		TypeKind.Set => makeRcInfo(RcKind.Set, "", "msSetFree", "msSetCopy", "msSetWasMoved", "msSetSink"),
		TypeKind.Object => classifyObject(t, ctx),
		TypeKind.TypeReference => classifyTypeRef(t, ctx),
		TypeKind.Distinct => { if (t.typeReturn !== null) { classifyType(t.typeReturn, ctx) } else { noRcInfo() } },
		TypeKind.Union | TypeKind.Result => makeRcInfo(RcKind.Named, "", "", "", "", ""),
		TypeKind.Tuple => {
			// Check if any element needs RC
			let hasRc = false;
			let i = 0;
			while (i < t.typeChildren.length) {
				if (classifyType(t.typeChildren[i], ctx).needsCleanup) { hasRc = true; }
				i += 1;
			}
			// TODO: Tuples with RC elements need per-field hooks from destructorLifting.
			// For now, emit Named with empty hooks (no-op cleanup).
			if (hasRc) { makeRcInfo(RcKind.Named, "", "", "", "", "") } else { noRcInfo() }
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
	const info = classifyType(null as unknown as Type, ctx);
	assert info.rcKind === RcKind.None;
}

test "string → String" {
	const ctx = createTransformContext();
	const info = classifyType(stringType(), ctx);
	assert info.rcKind === RcKind.String;
	assert info.needsCleanup;
	assert info.destroyFn === "msStringDecref";
	assert info.copyFn === "msStringIncref";
	assert info.wasMovedFn === "msStringWasMoved";
}

test "array of number → Array" {
	const ctx = createTransformContext();
	const info = classifyType(createArray(numberType()), ctx);
	assert info.rcKind === RcKind.Array;
	assert info.needsCleanup;
	assert info.destroyFn === "msArrayDestroy";
}

test "array of string → Array (string variant)" {
	const ctx = createTransformContext();
	const info = classifyType(createArray(stringType()), ctx);
	assert info.rcKind === RcKind.Array;
	assert info.destroyFn === "msArrayStringDestroy";
}

test "function → Closure" {
	const ctx = createTransformContext();
	const info = classifyType(createFunction([], [], voidType()), ctx);
	assert info.rcKind === RcKind.Closure;
	assert info.needsCleanup;
	assert info.destroyFn === "msClosureDestroy";
}

test "named object → Named" {
	const ctx = createTransformContext();
	const info = classifyType(createObject("Token", ["kind"], [numberType()], false), ctx);
	assert info.rcKind === RcKind.Named;
	assert info.needsCleanup;
	assert info.destroyFn === "Token_destroy";
	assert info.copyFn === "Token_copy";
	assert info.wasMovedFn === "Token_wasMoved";
}

test "anonymous object → None" {
	const ctx = createTransformContext();
	const info = classifyType(createObject("", ["x"], [numberType()], false), ctx);
	assert info.rcKind === RcKind.None;
}

test "ref → Ref" {
	const ctx = createTransformContext();
	const t = createPrimitive(TypeKind.Ref);
	const info = classifyType(t, ctx);
	assert info.rcKind === RcKind.Ref;
	assert info.destroyFn === "msDecref";
}

test "call is fresh" { assert isFreshExpr(NodeKind.CallExpr); }

test "new is fresh" { assert isFreshExpr(NodeKind.NewExpr); }

test "object literal is fresh" { assert isFreshExpr(NodeKind.ObjectLiteral); }

test "string literal is fresh" { assert isFreshExpr(NodeKind.StringLiteral); }

test "identifier is NOT fresh" { assert !isFreshExpr(NodeKind.Identifier); }

test "member access is NOT fresh" { assert !isFreshExpr(NodeKind.MemberExpr); }

test "binary expr is NOT fresh" { assert !isFreshExpr(NodeKind.BinaryExpr); }
