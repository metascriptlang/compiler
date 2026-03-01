// Type Classification for DRC — determines RC needs and runtime function names
//
// Each type maps to: no-op (primitive), runtime call (string/array/ref/closure/map/set),
// or generated lifecycle hook (named Object types from destructorLifting).
//
// The RcInfo result carries enough info to emit the correct AST calls.

import { Type, TypeKind, isPrimitiveKind, createPrimitive, createObject, createArray, createFunction, numberType, stringType, booleanType, voidType, nullType, unknownType } from "../checker/types";
import { lookupSymbol, SymbolKind, isPointerType as isPointerTypeBase } from "../checker/symbol";
import { TransformContext, createTransformContext } from "../transform/context";
import { NodeKind } from "../ast/node";
import { test, check, testGroup } from "std/testing";

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
		return makeRcInfo(RcKind.Named, t.typeName, t.typeName + "_destroy", t.typeName + "_copy", t.typeName + "_wasMoved", t.typeName + "_sink");
	}
	return noRcInfo();
}

function classifyTypeRef(t: Type, ctx: TransformContext): RcInfo {
	if (t.typeName === "" || ctx.checkerCtx === null) return noRcInfo();
	const sym = lookupSymbol(ctx.checkerCtx.table, t.typeName);
	if (sym === null) return noRcInfo();
	return classifyType(sym.symbolType, ctx);
}

// ===== Main Classification Entry Point =====

export function classifyType(t: Type, ctx: TransformContext): RcInfo {
	if (t === null) return noRcInfo();
	if (isPrimitiveKind(t.kind)) return noRcInfo();

	return match (t.kind) {
		TypeKind.String => makeRcInfo(RcKind.String, "", "msStringDecref", "msStringIncref", "msStringWasMoved", "msStringSink"),
		TypeKind.Array => classifyArray(t, ctx),
		TypeKind.Ref | TypeKind.Ptr => makeRcInfo(RcKind.Ref, "", "msDecref", "msIncref", "msPtrWasMoved", ""),
		TypeKind.Function => makeRcInfo(RcKind.Closure, "", "msClosureDestroy", "msClosureCopy", "msClosureWasMoved", "msClosureSink"),
		TypeKind.Map => makeRcInfo(RcKind.Map, "", "msMapFree", "msMapCopy", "msMapWasMoved", "msMapSink"),
		TypeKind.Set => makeRcInfo(RcKind.Set, "", "msSetFree", "msSetCopy", "", ""),
		TypeKind.Object => classifyObject(t, ctx),
		TypeKind.TypeReference => classifyTypeRef(t, ctx),
		TypeKind.Distinct => { if (t.typeReturn !== null) { classifyType(t.typeReturn, ctx) } else { noRcInfo() } },
		TypeKind.Union | TypeKind.Result => makeRcInfo(RcKind.Named, "", "", "", "", ""),
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

testGroup("Classify Primitives", () => {
	test("number → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(numberType(), ctx);
		check(info.rcKind === RcKind.None);
		check(!info.needsCleanup);
	});
	test("boolean → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(booleanType(), ctx);
		check(info.rcKind === RcKind.None);
	});
	test("void → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(voidType(), ctx);
		check(info.rcKind === RcKind.None);
	});
	test("null → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(nullType(), ctx);
		check(info.rcKind === RcKind.None);
	});
	test("unknown → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(unknownType(), ctx);
		check(info.rcKind === RcKind.None);
	});
	test("int32 → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(createPrimitive(TypeKind.Int32), ctx);
		check(info.rcKind === RcKind.None);
	});
	test("enum → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(createPrimitive(TypeKind.Enum), ctx);
		check(info.rcKind === RcKind.None);
	});
	test("null type input → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(null as unknown as Type, ctx);
		check(info.rcKind === RcKind.None);
	});
});

testGroup("Classify RC Types", () => {
	test("string → String", () => {
		const ctx = createTransformContext();
		const info = classifyType(stringType(), ctx);
		check(info.rcKind === RcKind.String);
		check(info.needsCleanup);
		check(info.destroyFn === "msStringDecref");
		check(info.copyFn === "msStringIncref");
		check(info.wasMovedFn === "msStringWasMoved");
	});
	test("array of number → Array", () => {
		const ctx = createTransformContext();
		const info = classifyType(createArray(numberType()), ctx);
		check(info.rcKind === RcKind.Array);
		check(info.needsCleanup);
		check(info.destroyFn === "msArrayDestroy");
	});
	test("array of string → Array (string variant)", () => {
		const ctx = createTransformContext();
		const info = classifyType(createArray(stringType()), ctx);
		check(info.rcKind === RcKind.Array);
		check(info.destroyFn === "msArrayStringDestroy");
	});
	test("function → Closure", () => {
		const ctx = createTransformContext();
		const info = classifyType(createFunction([], [], voidType()), ctx);
		check(info.rcKind === RcKind.Closure);
		check(info.needsCleanup);
		check(info.destroyFn === "msClosureDestroy");
	});
	test("named object → Named", () => {
		const ctx = createTransformContext();
		const info = classifyType(createObject("Token", ["kind"], [numberType()], false), ctx);
		check(info.rcKind === RcKind.Named);
		check(info.needsCleanup);
		check(info.destroyFn === "Token_destroy");
		check(info.copyFn === "Token_copy");
		check(info.wasMovedFn === "Token_wasMoved");
	});
	test("anonymous object → None", () => {
		const ctx = createTransformContext();
		const info = classifyType(createObject("", ["x"], [numberType()], false), ctx);
		check(info.rcKind === RcKind.None);
	});
	test("ref → Ref", () => {
		const ctx = createTransformContext();
		const t = createPrimitive(TypeKind.Ref);
		const info = classifyType(t, ctx);
		check(info.rcKind === RcKind.Ref);
		check(info.destroyFn === "msDecref");
	});
});

testGroup("Classify isFreshExpr", () => {
	test("call is fresh", () => {
		check(isFreshExpr(NodeKind.CallExpr));
	});
	test("new is fresh", () => {
		check(isFreshExpr(NodeKind.NewExpr));
	});
	test("object literal is fresh", () => {
		check(isFreshExpr(NodeKind.ObjectLiteral));
	});
	test("string literal is fresh", () => {
		check(isFreshExpr(NodeKind.StringLiteral));
	});
	test("identifier is NOT fresh", () => {
		check(!isFreshExpr(NodeKind.Identifier));
	});
	test("member access is NOT fresh", () => {
		check(!isFreshExpr(NodeKind.MemberExpr));
	});
	test("binary expr is NOT fresh", () => {
		check(!isFreshExpr(NodeKind.BinaryExpr));
	});
});
