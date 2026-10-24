// Integer conversion materialization (JS backend) — docs/JS-NUMERIC.md §5.
// The checker parks every narrowing integer conversion on a HiddenStdConv, and
// the programmer's own `as` on a TypeAssertion. C materializes both into
// msCheckRangeI32(...) in rangeCheckInject; JS has to materialize the SAME two
// nodes into the operator that truncates, or the fraction survives the
// conversion: `const x: int32 = f` emitted `3.9` on JS against `3` on C.

import { Node, NodeKind, NodeFlag, TypeAssertionData, HiddenStdConvData, BinaryExprData, ExprStmtData, SourceLocation, Type, TypeKind, VariableDeclData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeCall, makeMember, makeNumber, generatedRef, runtimeRef } from "../util";
import { createPrimitive, isWideningInt64Conv, peelToRepr, distinctNumericBase } from "../../checker/types";
import { readsUnionMember } from "./bigIntJS";
import { is64Kind, isFloatKind, isNarrowIntKind } from "../numKinds";
import { rangeCheckHelper, makeRangeCheckFor } from "../native/rangeCheckInject";
import { parseInput, makeJsCtx, getStmts, firstExprKindAfter, castOf } from "../testUtil";
import { checkProgramJs } from "../../checker/checkPass";

export function lowerIntConvJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, materializeIntConv);
	return program;
}

export function injectRangeChecksJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => checkConvRange(node, ctx));
	return program;
}

function checkConvRange(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		if (d.asExpr == null || node.nodeType == null) return node;
		d.asExpr = checkedSource(d.asExpr, distinctNumericBase(node.nodeType) ?? node.nodeType, ctx);
		return node;
	}
	if (node.kind == NodeKind.HiddenStdConv) {
		const d = node.data as HiddenStdConvData;
		if (d.convType == null || d.convExpr == null) return node;
		d.convExpr = checkedSource(d.convExpr, d.convType, ctx);
	}
	return node;
}

function checkedSource(expr: Node, dest: Type, ctx: TransformContext): Node {
	const fnName = rangeCheckHelper(expr.nodeType, dest, ctx.rangeChecks);
	if (fnName == "") return expr;
	const call = makeRangeCheckFor(fnName, expr, dest, expr.location);
	call.nodeType = expr.nodeType;
	return call;
}

function materializeIntConv(node: Node): Node {
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		if (node.nodeType == null || d.asType == "!") return node;
		const kind = (distinctNumericBase(node.nodeType) ?? node.nodeType).kind;
		if (node.flags.has(NodeFlag.ConvCheck)) return isIntConvKind(kind) && !readsUnionMember(d) ? truncateTo(node, kind, node.location) : node;
		if (kind == TypeKind.Char) return d.asExpr != null && isByteSource(d.asExpr.nodeType) ? truncateTo(d.asExpr, kind, node.location) : node;
		if (!isIntConvKind(kind)) {
			if (isFloatKind(kind) && d.asExpr != null) {
				const srcT = d.asExpr.nodeType;
				if (srcT != null && is64Kind(srcT.kind)) {
					return numberOf64(d.asExpr, kind == TypeKind.Float32 ? TypeKind.Float32 : TypeKind.Float64, node.location);
				}
			}
			return node;
		}
		return truncateTo(d.asExpr, kind, node.location);
	}
	if (node.kind == NodeKind.HiddenStdConv) {
		const d = node.data as HiddenStdConvData;
		if (d.convType == null) return node;
		if (isFloatKind(d.convType.kind)) {
			// int64 is a BigInt at runtime on js; widening to a float must go
			// through Number() or the BigInt leaks into arithmetic as-is.
			const srcT = d.convExpr != null ? d.convExpr.nodeType : null;
			if (srcT != null && is64Kind(srcT.kind)) {
				return numberOf64(d.convExpr, d.convType.kind, node.location);
			}
		}
		if (d.convType.kind == TypeKind.Char) return isByteSource(d.convExpr != null ? d.convExpr.nodeType : null) ? truncateTo(d.convExpr, TypeKind.Char, node.location) : node;
		if (!isIntConvKind(d.convType.kind)) return node;
		// A widening conv marks the 64-bit boundary for BigInt mode; in Number
		// mode the value is already integral, so the node just drops at codegen.
		const srcT = d.convExpr != null ? d.convExpr.nodeType : null;
		if (srcT != null && isWideningInt64Conv(srcT, d.convType)) return node;
		return truncateTo(d.convExpr, d.convType.kind, node.location);
	}
	return node;
}

function numberOf64(inner: Node, kind: TypeKind, loc: SourceLocation): Node {
	const result = makeCall(generatedRef("Number", loc), [inner], loc);
	result.nodeType = createPrimitive(kind);
	return result;
}

// Mask and shift truncate a float on their own — `3.9 & 0xff` is 3 — so the
// 32-bit widths need no Math.trunc ahead of them. int64 has no 32-bit operator
// and takes the call. `Math` stays symbol-less on purpose: binding it would
// reach the prelude's own `class Math` and the JS naming oracle would mangle
// it, so this pass has to run after resolveRuntimeIdents.
export function truncateTo(inner: Node, kind: TypeKind, loc: SourceLocation): Node {
	const result = match (kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 => makeBinary(inner, "|", makeNumber(0, loc), loc),
		TypeKind.Uint8 | TypeKind.Char => makeBinary(inner, "&", makeNumber(255, loc), loc),
		TypeKind.Uint16 => makeBinary(inner, "&", makeNumber(65535, loc), loc),
		TypeKind.Uint32 => makeBinary(inner, ">>>", makeNumber(0, loc), loc),
		TypeKind.Int64 | TypeKind.Uint64 => makeCall(makeMember(generatedRef("Math", loc), "trunc", loc), [inner], loc),
		_ => inner,
	};
	result.nodeType = createPrimitive(kind);
	return result;
}

function isByteSource(t: Type | null): boolean {
	const r = peelToRepr(t);
	if (r == null) return false;
	const kind = r.kind == TypeKind.Enum ? TypeKind.Int32 : r.kind;
	return isFloatKind(kind) || (isIntConvKind(kind) && !is64Kind(kind));
}

export function isIntConvKind(kind: TypeKind): boolean {
	return isNarrowIntKind(kind) || is64Kind(kind);
}

// ===== Test Helpers =====

function castResult(input: string): Node | null {
	const result = parseInput(input);
	if (!result.ok) return null;
	checkProgramJs(result.value);
	lowerIntConvJS(result.value, makeJsCtx());
	const found: Node[] = [];
	walkNode(result.value, (n: Node): Node => {
		if (n.kind == NodeKind.VariableDecl && (n.data as VariableDeclData).declName == "r") found.push((n.data as VariableDeclData).initializer);
		return n;
	});
	return found.length > 0 ? found[0] : null;
}

function castOp(input: string): string {
	const r = castResult(input);
	if (r == null || r.kind != NodeKind.BinaryExpr) return "";
	return (r.data as BinaryExprData).operator;
}

function castKind(input: string): NodeKind {
	const r = castResult(input);
	return r != null ? r.kind : NodeKind.Program;
}

// ===== Tests =====

test "int32 cast truncates with or" { assert castOp(castOf("int32")) == "|"; }

test "int8 cast truncates with or" { assert castOp(castOf("int8")) == "|"; }

test "uint8 cast masks to a byte" { assert castOp(castOf("uint8")) == "&"; }

test "uint16 cast masks to a half" { assert castOp(castOf("uint16")) == "&"; }

test "uint32 cast shifts unsigned" { assert castOp(castOf("uint32")) == ">>>"; }

test "int64 cast becomes a call" { assert castKind(castOf("int64")) == NodeKind.CallExpr; }

test "a cast to an alias of uint8 masks to a byte" { assert castOp("type Byte = uint8;\n" + castOf("Byte")) == "&"; }

test "cast to number unchanged" { assert castKind(castOf("number")) == NodeKind.TypeAssertion; }

test "cast to string unchanged" { assert castKind("function f(v: string): void { const r = v as string; }") == NodeKind.TypeAssertion; }

test "non-cast unchanged" { assert castOp("function f(x: int32, y: int32): void { const r = x + y; }") == "+"; }

test "identifier unchanged" { assert firstExprKindAfter("x;", lowerIntConvJS) == NodeKind.Identifier; }
