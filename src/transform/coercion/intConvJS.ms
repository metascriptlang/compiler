// Integer conversion materialization (JS backend) — docs/JS-NUMERIC.md §5.
// The checker parks every narrowing integer conversion on a HiddenStdConv, and
// the programmer's own `as` on a TypeAssertion. C materializes both into
// msCheckRangeI32(...) in rangeCheckInject; JS has to materialize the SAME two
// nodes into the operator that truncates, or the fraction survives the
// conversion: `const x: int32 = f` emitted `3.9` on JS against `3` on C.

import { Node, NodeKind, TypeAssertionData, HiddenStdConvData, BinaryExprData, ExprStmtData, SourceLocation, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeCall, makeIdent, makeMember, makeNumber } from "../util";
import { createPrimitive, isWideningInt64Conv } from "../../checker/types";
import { isFloatKind } from "./bigIntJS";
import { parseInput, makeCtx, getStmts, firstExprKindAfter } from "../testUtil";

export function lowerIntConvJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, materializeIntConv);
	return program;
}

function materializeIntConv(node: Node): Node {
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		const kind = intKindOfName(d.asType);
		if (kind == TypeKind.Unknown) {
			const floatKind = floatKindOfName(d.asType);
			if (floatKind != TypeKind.Unknown && d.asExpr != null) {
				const srcT = d.asExpr.nodeType;
				if (srcT != null && (srcT.kind == TypeKind.Int64 || srcT.kind == TypeKind.Uint64)) {
					return numberOf64(d.asExpr, floatKind, node.location);
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
			if (srcT != null && (srcT.kind == TypeKind.Int64 || srcT.kind == TypeKind.Uint64)) {
				return numberOf64(d.convExpr, d.convType.kind, node.location);
			}
		}
		if (!isIntConvKind(d.convType.kind)) return node;
		// A widening conv marks the 64-bit boundary for BigInt mode; in Number
		// mode the value is already integral, so the node just drops at codegen.
		const srcT = d.convExpr != null ? d.convExpr.nodeType : null;
		if (srcT != null && isWideningInt64Conv(srcT, d.convType)) return node;
		return truncateTo(d.convExpr, d.convType.kind, node.location);
	}
	return node;
}

function floatKindOfName(name: string): TypeKind {
	return match (name) {
		"float32" => TypeKind.Float32,
		"float64" | "number" => TypeKind.Float64,
		_ => TypeKind.Unknown,
	};
}

function numberOf64(inner: Node, kind: TypeKind, loc: SourceLocation): Node {
	const result = makeCall(makeIdent("Number", loc), [inner], loc);
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
		TypeKind.Uint8 => makeBinary(inner, "&", makeNumber(255, loc), loc),
		TypeKind.Uint16 => makeBinary(inner, "&", makeNumber(65535, loc), loc),
		TypeKind.Uint32 => makeBinary(inner, ">>>", makeNumber(0, loc), loc),
		TypeKind.Int64 | TypeKind.Uint64 => makeCall(makeMember(makeIdent("Math", loc), "trunc", loc), [inner], loc),
		_ => inner,
	};
	result.nodeType = createPrimitive(kind);
	return result;
}

export function isIntConvKind(kind: TypeKind): boolean {
	return match (kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 => true,
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 => true,
		TypeKind.Int64 | TypeKind.Uint64 => true,
		_ => false,
	};
}

function intKindOfName(name: string): TypeKind {
	return match (name) {
		"int8" => TypeKind.Int8,
		"int16" => TypeKind.Int16,
		"int32" => TypeKind.Int32,
		"int64" => TypeKind.Int64,
		"uint8" => TypeKind.Uint8,
		"uint16" => TypeKind.Uint16,
		"uint32" => TypeKind.Uint32,
		"uint64" => TypeKind.Uint64,
		_ => TypeKind.Unknown,
	};
}

// ===== Test Helpers =====

function castOp(input: string): string {
	const result = parseInput(input);
	if (!result.ok) return "";
	const ctx = makeCtx();
	lowerIntConvJS(result.value, ctx);
	const stmts = getStmts(result.value);
	if (stmts.length == 0) return "";
	if (stmts[0].kind != NodeKind.ExprStmt) return "";
	const sd = stmts[0].data as ExprStmtData;
	if (sd.expr.kind != NodeKind.BinaryExpr) return "";
	return (sd.expr.data as BinaryExprData).operator;
}

// ===== Tests =====

test "int32 cast truncates with or" { assert castOp("x as int32;") == "|"; }

test "int8 cast truncates with or" { assert castOp("x as int8;") == "|"; }

test "uint8 cast masks to a byte" { assert castOp("x as uint8;") == "&"; }

test "uint16 cast masks to a half" { assert castOp("x as uint16;") == "&"; }

test "uint32 cast shifts unsigned" { assert castOp("x as uint32;") == ">>>"; }

test "int64 cast becomes a call" { assert firstExprKindAfter("x as int64;", lowerIntConvJS) == NodeKind.CallExpr; }

test "cast to number unchanged" { assert firstExprKindAfter("x as number;", lowerIntConvJS) == NodeKind.TypeAssertion; }

test "cast to string unchanged" { assert firstExprKindAfter("x as string;", lowerIntConvJS) == NodeKind.TypeAssertion; }

test "non-cast unchanged" { assert castOp("x + y;") == "+"; }

test "identifier unchanged" { assert firstExprKindAfter("x;", lowerIntConvJS) == NodeKind.Identifier; }
