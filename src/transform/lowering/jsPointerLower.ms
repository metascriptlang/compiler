import {
	Node, NodeKind, Type, TypeKind, DeclKind, SourceLocation, TypeAssertionData, NumberLiteralData,
	HiddenDerefData, HiddenStdConvData, ArrayAccessData, MemberExprData, BinaryExprData,
	VariableDeclData, CallExprData, FunctionDeclData, ReturnStmtData, ObjectLiteralData,
	ArrayLiteralData, ConditionalExprData, BlockStmtData, ProgramData, MethodDeclData,
	ConstructorDeclData, FunctionExprData, ArrowFunctionData, NewExprData, createNodeAt,
} from "../../ast/node";
import { skipModifier, peelTransparentInstance } from "../../checker/types";
import { nonNullMemberOfNullable } from "../../checker/compat";
import { getCtorParamTypes } from "../../checker/symbol";
import { TransformContext, freshTempSym, reportTransformError } from "../context";
import { mapChildren } from "../walker";
import { makeIdentResolved, makeNumber, makeArrayAccess, makeBinary, makeVarDecl, makeBlock, makeReturn } from "../util";

function bare(t: Type | null): Type | null {
	let cur = skipModifier(t);
	if (cur == null) return null;
	const nonNull = nonNullMemberOfNullable(cur);
	if (nonNull != null) cur = nonNull;
	return peelTransparentInstance(cur);
}

function typedPointer(t: Type | null): boolean {
	const b = bare(t);
	if (b == null || b.kind != TypeKind.Ptr || b.typeReturn == null || b.typeReturn.kind == TypeKind.Void) return false;
	const pointee = bare(b.typeReturn);
	return pointee != null && pointee.kind != TypeKind.Ref;
}

function untyped(node: Node): Node {
	const result = createNodeAt(node.kind, node.data, node.location);
	result.resolvedSym = node.resolvedSym;
	result.flags = node.flags;
	return result;
}

function pair(base: Node, index: Node, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.ArrayLiteral, { elements: [untyped(base), index] }, loc);
}

function part(pointer: Node, index: number): Node {
	return makeArrayAccess(untyped(pointer), makeNumber(index, pointer.location), pointer.location);
}

function hoisted(value: Node, ctx: TransformContext, temps: Node[]): Node[] {
	if (value.kind == NodeKind.Identifier) return [value, value];
	const sym = freshTempSym(ctx, "ptrTemp", null);
	const decl = makeVarDecl(sym.name, null as unknown as Node, DeclKind.Let, value.location);
	decl.resolvedSym = sym;
	temps.push(decl);
	const read = makeIdentResolved(sym, value.location);
	return [makeBinary(read, "=", untyped(value), value.location), read];
}

function pointerPlace(pointer: Node, ctx: TransformContext, temps: Node[]): Node {
	const once = hoisted(pointer, ctx, temps);
	return makeArrayAccess(part(once[0], 0), part(once[1], 1), pointer.location);
}

function pointerEqual(left: Node, right: Node, negate: boolean, objectPointee: boolean, ctx: TransformContext, temps: Node[]): Node {
	const loc = left.location;
	const a = hoisted(left, ctx, temps);
	const b = hoisted(right, ctx, temps);
	const nil = createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc);
	const sameBase = makeBinary(part(a[1], 0), "===", part(b[1], 0), loc);
	const sameIndex = makeBinary(part(a[1], 1), "===", part(b[1], 1), loc);
	const equal = objectPointee
		? makeBinary(makeArrayAccess(part(a[1], 0), part(a[1], 1), loc), "===", makeArrayAccess(part(b[1], 0), part(b[1], 1), loc), loc)
		: makeBinary(sameBase, "&&", sameIndex, loc);
	const nonNull = makeBinary(makeBinary(a[1], "!==", nil, loc), "&&", makeBinary(b[1], "!==", nil, loc), loc);
	const same = makeBinary(makeBinary(a[0], "===", b[0], loc), "||", makeBinary(nonNull, "&&", equal, loc), loc);
	return negate ? createNodeAt(NodeKind.UnaryExpr, { unaryOp: "!", operand: same }, loc) : same;
}

let pointerCtx: TransformContext = null as unknown as TransformContext;
let returnTypes: (Type | null)[] = [];
let tempScopes: Node[][] = [];

function convert(value: Node, target: Type | null): Node {
	const ctx = pointerCtx;
	const source = bare(value.nodeType);
	const dest = bare(target);
	if (source == null || dest == null || value.kind == NodeKind.NullLiteral) return rewrite(value);
	if (typedPointer(dest) && !typedPointer(source) && source.kind == TypeKind.Ref) {
		const loc = value.location;
		const once = hoisted(rewrite(value), ctx, tempScopes[tempScopes.length - 1]);
		const nil = createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc);
		const cell = createNodeAt(NodeKind.ArrayLiteral, { elements: [once[1]] }, loc);
		const result = createNodeAt(NodeKind.ConditionalExpr, {
			ternaryCondition: makeBinary(once[0], "===", nil, loc),
			ternaryConsequent: nil, ternaryAlternate: pair(cell, makeNumber(0, loc), loc),
		}, loc);
		result.nodeType = target;
		return result;
	}
	if (typedPointer(source) && dest.kind == TypeKind.Ref) {
		const result = pointerPlace(rewrite(value), ctx, tempScopes[tempScopes.length - 1]);
		result.nodeType = target;
		return result;
	}
	return rewrite(value);
}

function rewrite(node: Node): Node {
	const ctx = pointerCtx;
	if (node == null) return node;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl) {
		const t = node.resolvedSym != null ? node.resolvedSym.symbolType : node.nodeType;
		returnTypes.push(t != null ? t.typeReturn : null);
		tempScopes.push([]);
		mapChildren(node, rewrite);
		const temps = tempScopes.pop()!;
		if (temps.length > 0) {
			let body: Node;
			if (node.kind == NodeKind.FunctionDecl) body = (node.data as FunctionDeclData).fnBody;
			else if (node.kind == NodeKind.ArrowFunction) body = (node.data as ArrowFunctionData).arrowBody;
			else if (node.kind == NodeKind.FunctionExpr) body = (node.data as FunctionExprData).funcExprBody;
			else if (node.kind == NodeKind.MethodDecl) body = (node.data as MethodDeclData).methodBody;
			else body = (node.data as ConstructorDeclData).ctorBody;
			if (body.kind == NodeKind.BlockStmt) {
				const d = body.data as BlockStmtData;
				for (const s of d.statements) temps.push(s);
				d.statements = temps;
			} else {
				temps.push(makeReturn(body, body.location));
				body = makeBlock(temps, body.location);
				(node.data as ArrowFunctionData).arrowBody = body;
			}
		}
		returnTypes.pop();
		return node;
	}
	if (node.kind == NodeKind.TypeAssertion || node.kind == NodeKind.HiddenStdConv || node.kind == NodeKind.HiddenSubConv) {
		const assertion = node.kind == NodeKind.TypeAssertion;
		const value = assertion ? (node.data as TypeAssertionData).asExpr : (node.data as HiddenStdConvData).convExpr;
		const target = assertion ? node.nodeType : (node.data as HiddenStdConvData).convType;
		if (typedPointer(target) || typedPointer(value.nodeType)) return convert(value, target);
		mapChildren(node, rewrite);
		return node;
	}
	if (node.kind == NodeKind.HiddenDeref) {
		const d = node.data as HiddenDerefData;
		if (typedPointer(d.expr.nodeType)) {
			const result = pointerPlace(rewrite(d.expr), ctx, tempScopes[tempScopes.length - 1]);
			result.nodeType = node.nodeType;
			return result;
		}
	}
	if (node.kind == NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		if (typedPointer(d.array.nodeType)) {
			if (d.index.kind != NodeKind.NumberLiteral || (d.index.data as NumberLiteralData).value != 0) {
				reportTransformError(ctx, "internal: a pointer index other than 0 reached the JS pointer lowering; the checker refuses it on JS", node.location);
				return node;
			}
			const result = pointerPlace(rewrite(d.array), ctx, tempScopes[tempScopes.length - 1]);
			result.nodeType = node.nodeType;
			return result;
		}
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const source = bare(d.object.nodeType);
		if (typedPointer(source)) {
			const object = pointerPlace(rewrite(d.object), ctx, tempScopes[tempScopes.length - 1]);
			object.nodeType = source != null ? source.typeReturn : null;
			d.object = object;
			return node;
		}
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		const lp = typedPointer(d.left.nodeType);
		const rp = typedPointer(d.right.nodeType);
		if (d.operator == "=") {
			d.right = convert(d.right, d.left.nodeType);
			d.left = rewrite(d.left);
			return node;
		}
		if (lp || rp) {
			let result: Node | null = null;
			if (d.operator == "==" || d.operator == "===" || d.operator == "!=" || d.operator == "!==") {
				const lt = bare(d.left.nodeType);
				const rt = bare(d.right.nodeType);
				if (lt != null && rt != null && lt.kind != TypeKind.Null && rt.kind != TypeKind.Null) {
					const pt = lt != null ? bare(lt.typeReturn) : null;
					const object = pt != null && (pt.kind == TypeKind.Struct || pt.kind == TypeKind.Ref || pt.kind == TypeKind.Array || pt.kind == TypeKind.SizedArray || pt.kind == TypeKind.Tuple);
					result = pointerEqual(rewrite(d.left), rewrite(d.right), d.operator == "!=" || d.operator == "!==", object, ctx, tempScopes[tempScopes.length - 1]);
				}
			} else {
				reportTransformError(ctx, "internal: pointer operator '" + d.operator + "' reached the JS pointer lowering; the checker refuses it on JS", node.location);
			}
			if (result != null) {
				result.nodeType = node.nodeType;
				return result;
			}
		}
	}
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (d.initializer != null) d.initializer = convert(d.initializer, node.nodeType);
		return node;
	}
	if (node.kind == NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		if (d.argument != null) d.argument = convert(d.argument, returnTypes.length > 0 ? returnTypes[returnTypes.length - 1] : null);
		return node;
	}
	if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		const t = d.callee.nodeType != null ? d.callee.nodeType : d.callee.resolvedSym != null ? d.callee.resolvedSym.symbolType : null;
		for (let i = 0; i < d.arguments.length; i += 1) {
			d.arguments[i] = convert(d.arguments[i], t != null && t.kind == TypeKind.Function && i < t.typeChildren.length ? t.typeChildren[i] : null);
		}
		d.callee = rewrite(d.callee);
		return node;
	}
	if (node.kind == NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		const formals = d.newCallee.resolvedSym != null ? getCtorParamTypes(d.newCallee.resolvedSym) : null;
		for (let i = 0; i < d.newArguments.length; i += 1) d.newArguments[i] = convert(d.newArguments[i], formals != null && i < formals.length ? formals[i] : null);
		d.newCallee = rewrite(d.newCallee);
		return node;
	}
	if (node.kind == NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		let t = bare(node.nodeType);
		if (t != null && t.kind == TypeKind.Ref) t = bare(t.typeReturn);
		for (let i = 0; i < d.properties.length; i += 1) {
			let field: Type | null = null;
			if (t != null && i < d.keys.length) {
				for (let j = 0; j < t.typeNames.length && j < t.typeChildren.length; j += 1) {
					if (t.typeNames[j] == d.keys[i]) field = t.typeChildren[j];
				}
			}
			d.properties[i] = convert(d.properties[i], field);
		}
		return node;
	}
	if (node.kind == NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		let t = bare(node.nodeType);
		if (t != null && t.kind == TypeKind.Ref) t = bare(t.typeReturn);
		for (let i = 0; i < d.elements.length; i += 1) d.elements[i] = convert(d.elements[i], t != null ? t.typeReturn : null);
		return node;
	}
	if (node.kind == NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		d.ternaryCondition = rewrite(d.ternaryCondition);
		d.ternaryConsequent = convert(d.ternaryConsequent, node.nodeType);
		d.ternaryAlternate = convert(d.ternaryAlternate, node.nodeType);
		return node;
	}
	mapChildren(node, rewrite);
	return node;
}

export function lowerJsPointers(program: Node, ctx: TransformContext): Node {
	pointerCtx = ctx;
	returnTypes = [];
	tempScopes = [[]];
	const result = rewrite(program);
	if (result.kind == NodeKind.Program && tempScopes[0].length > 0) {
		const d = result.data as ProgramData;
		const stmts = tempScopes[0];
		for (const s of d.programStmts) stmts.push(s);
		d.programStmts = stmts;
	}
	pointerCtx = null as unknown as TransformContext;
	returnTypes = [];
	tempScopes = [];
	return result;
}
