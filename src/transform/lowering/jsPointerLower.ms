import {
	Node, NodeKind, Type, TypeKind, DeclKind, SourceLocation, TypeAssertionData, NumberLiteralData,
	HiddenDerefData, HiddenStdConvData, ArrayAccessData, MemberExprData, BinaryExprData,
	VariableDeclData, CallExprData, FunctionDeclData, ReturnStmtData, ObjectLiteralData,
	ArrayLiteralData, ConditionalExprData, BlockStmtData, ProgramData, MethodDeclData,
	ConstructorDeclData, FunctionExprData, ArrowFunctionData, NewExprData, createNodeAt,
} from "../../ast/node";
import { skipModifier, peelTransparentInstance } from "../../checker/types";
import { nonNullMemberOfNullable } from "../../checker/compat";
import { ctorFormalTypes } from "../../checker/ctorRoutine";
import { TransformContext, freshTempSym, reportTransformError } from "../context";
import { mapChildren } from "../walker";
import { isRoutineNode } from "../../ast/shape";
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

interface PointerRun {
	ctx: TransformContext;
	returnTypes: (Type | null)[];
	tempScopes: Node[][];
}

function convert(value: Node, target: Type | null, run: PointerRun): Node {
	const ctx = run.ctx;
	const source = bare(value.nodeType);
	const dest = bare(target);
	if (source == null || dest == null || value.kind == NodeKind.NullLiteral) return rewrite(value, run);
	if (typedPointer(dest) && !typedPointer(source) && source.kind == TypeKind.Ref) {
		const loc = value.location;
		const once = hoisted(rewrite(value, run), ctx, currentTemps(run));
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
		const result = pointerPlace(rewrite(value, run), ctx, currentTemps(run));
		result.nodeType = target;
		return result;
	}
	return rewrite(value, run);
}

function rewrite(node: Node, run: PointerRun): Node {
	if (node == null) return node;
	if (isRoutineNode(node)) return rewriteRoutine(node, run);
	return match (node.kind) {
		NodeKind.TypeAssertion | NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => rewriteConversion(node, run),
		NodeKind.HiddenDeref => rewriteDeref(node, run),
		NodeKind.ArrayAccess => rewriteIndex(node, run),
		NodeKind.MemberExpr => rewriteMember(node, run),
		NodeKind.BinaryExpr => rewriteBinary(node, run),
		NodeKind.VariableDecl => rewriteVariable(node, run),
		NodeKind.ReturnStmt => rewriteReturn(node, run),
		NodeKind.CallExpr => rewriteCall(node, run),
		NodeKind.NewExpr => rewriteNew(node, run),
		NodeKind.ObjectLiteral => rewriteObject(node, run),
		NodeKind.ArrayLiteral => rewriteArray(node, run),
		NodeKind.ConditionalExpr => rewriteConditional(node, run),
		_ => rewriteChildren(node, run),
	};
}

function rewriteChildren(node: Node, run: PointerRun): Node {
	mapChildren(node, (child: Node): Node => rewrite(child, run));
	return node;
}

function currentTemps(run: PointerRun): Node[] {
	return run.tempScopes[run.tempScopes.length - 1];
}

function routineBody(node: Node): Node {
	return match (node.kind) {
		NodeKind.FunctionDecl => (node.data as FunctionDeclData).fnBody,
		NodeKind.ArrowFunction => (node.data as ArrowFunctionData).arrowBody,
		NodeKind.FunctionExpr => (node.data as FunctionExprData).funcExprBody,
		NodeKind.MethodDecl => (node.data as MethodDeclData).methodBody,
		_ => (node.data as ConstructorDeclData).ctorBody,
	};
}

function rewriteRoutine(node: Node, run: PointerRun): Node {
	const t = node.resolvedSym != null ? node.resolvedSym.symbolType : node.nodeType;
	run.returnTypes.push(t != null ? t.typeReturn : null);
	run.tempScopes.push([]);
	mapChildren(node, (child: Node): Node => rewrite(child, run));
	const temps = run.tempScopes.pop()!;
	if (temps.length > 0) {
		const body = routineBody(node);
		if (body.kind == NodeKind.BlockStmt) {
			const d = body.data as BlockStmtData;
			for (const s of d.statements) temps.push(s);
			d.statements = temps;
		} else {
			temps.push(makeReturn(body, body.location));
			(node.data as ArrowFunctionData).arrowBody = makeBlock(temps, body.location);
		}
	}
	run.returnTypes.pop();
	return node;
}

function rewriteConversion(node: Node, run: PointerRun): Node {
	const assertion = node.kind == NodeKind.TypeAssertion;
	const value = assertion ? (node.data as TypeAssertionData).asExpr : (node.data as HiddenStdConvData).convExpr;
	const target = assertion ? node.nodeType : (node.data as HiddenStdConvData).convType;
	if (typedPointer(target) || typedPointer(value.nodeType)) return convert(value, target, run);
	return rewriteChildren(node, run);
}

function rewriteDeref(node: Node, run: PointerRun): Node {
	const d = node.data as HiddenDerefData;
	if (!typedPointer(d.expr.nodeType)) return rewriteChildren(node, run);
	const result = pointerPlace(rewrite(d.expr, run), run.ctx, currentTemps(run));
	result.nodeType = node.nodeType;
	return result;
}

function rewriteIndex(node: Node, run: PointerRun): Node {
	const d = node.data as ArrayAccessData;
	if (!typedPointer(d.array.nodeType)) return rewriteChildren(node, run);
	if (d.index.kind != NodeKind.NumberLiteral || (d.index.data as NumberLiteralData).value != 0) {
		reportTransformError(run.ctx, "internal: a pointer index other than 0 reached the JS pointer lowering; the checker refuses it on JS", node.location);
		return node;
	}
	const result = pointerPlace(rewrite(d.array, run), run.ctx, currentTemps(run));
	result.nodeType = node.nodeType;
	return result;
}

function rewriteMember(node: Node, run: PointerRun): Node {
	const d = node.data as MemberExprData;
	const source = bare(d.object.nodeType);
	if (!typedPointer(source)) return rewriteChildren(node, run);
	const object = pointerPlace(rewrite(d.object, run), run.ctx, currentTemps(run));
	object.nodeType = source != null ? source.typeReturn : null;
	d.object = object;
	return node;
}

function rewriteBinary(node: Node, run: PointerRun): Node {
	const d = node.data as BinaryExprData;
	if (d.operator == "=") {
		d.right = convert(d.right, d.left.nodeType, run);
		d.left = rewrite(d.left, run);
		return node;
	}
	if (!typedPointer(d.left.nodeType) && !typedPointer(d.right.nodeType)) return rewriteChildren(node, run);
	if (d.operator != "==" && d.operator != "===" && d.operator != "!=" && d.operator != "!==") {
		reportTransformError(run.ctx, "internal: pointer operator '" + d.operator + "' reached the JS pointer lowering; the checker refuses it on JS", node.location);
		return rewriteChildren(node, run);
	}
	const lt = bare(d.left.nodeType);
	const rt = bare(d.right.nodeType);
	if (lt == null || rt == null || lt.kind == TypeKind.Null || rt.kind == TypeKind.Null) return rewriteChildren(node, run);
	const pt = bare(lt.typeReturn);
	const object = pt != null && (pt.kind == TypeKind.Struct || pt.kind == TypeKind.Ref || pt.kind == TypeKind.Array || pt.kind == TypeKind.SizedArray || pt.kind == TypeKind.Tuple);
	const result = pointerEqual(rewrite(d.left, run), rewrite(d.right, run), d.operator == "!=" || d.operator == "!==", object, run.ctx, currentTemps(run));
	result.nodeType = node.nodeType;
	return result;
}

function rewriteVariable(node: Node, run: PointerRun): Node {
	const d = node.data as VariableDeclData;
	if (d.initializer != null) d.initializer = convert(d.initializer, node.nodeType, run);
	return node;
}

function rewriteReturn(node: Node, run: PointerRun): Node {
	const d = node.data as ReturnStmtData;
	if (d.argument != null) d.argument = convert(d.argument, run.returnTypes.length > 0 ? run.returnTypes[run.returnTypes.length - 1] : null, run);
	return node;
}

function rewriteCall(node: Node, run: PointerRun): Node {
	const d = node.data as CallExprData;
	const t = d.callee.nodeType != null ? d.callee.nodeType : d.callee.resolvedSym != null ? d.callee.resolvedSym.symbolType : null;
	for (let i = 0; i < d.arguments.length; i += 1) {
		d.arguments[i] = convert(d.arguments[i], t != null && t.kind == TypeKind.Function && i < t.typeChildren.length ? t.typeChildren[i] : null, run);
	}
	d.callee = rewrite(d.callee, run);
	return node;
}

function rewriteNew(node: Node, run: PointerRun): Node {
	const d = node.data as NewExprData;
	const formals = ctorFormalTypes(node.resolvedSym);
	for (let i = 0; i < d.newArguments.length; i += 1) d.newArguments[i] = convert(d.newArguments[i], formals != null && i < formals.length ? formals[i] : null, run);
	d.newCallee = rewrite(d.newCallee, run);
	return node;
}

function rewriteObject(node: Node, run: PointerRun): Node {
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
		d.properties[i] = convert(d.properties[i], field, run);
	}
	return node;
}

function rewriteArray(node: Node, run: PointerRun): Node {
	const d = node.data as ArrayLiteralData;
	let t = bare(node.nodeType);
	if (t != null && t.kind == TypeKind.Ref) t = bare(t.typeReturn);
	for (let i = 0; i < d.elements.length; i += 1) d.elements[i] = convert(d.elements[i], t != null ? t.typeReturn : null, run);
	return node;
}

function rewriteConditional(node: Node, run: PointerRun): Node {
	const d = node.data as ConditionalExprData;
	d.ternaryCondition = rewrite(d.ternaryCondition, run);
	d.ternaryConsequent = convert(d.ternaryConsequent, node.nodeType, run);
	d.ternaryAlternate = convert(d.ternaryAlternate, node.nodeType, run);
	return node;
}

export function lowerJsPointers(program: Node, ctx: TransformContext): Node {
	const run: PointerRun = { ctx, returnTypes: [], tempScopes: [[]] };
	const result = rewrite(program, run);
	if (result.kind == NodeKind.Program && run.tempScopes[0].length > 0) {
		const d = result.data as ProgramData;
		const stmts = run.tempScopes[0];
		for (const s of d.programStmts) stmts.push(s);
		d.programStmts = stmts;
	}
	return result;
}
