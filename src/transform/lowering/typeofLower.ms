// `typeof x` reads the compiler's tag table on every backend (CK-181). Converted
// to a string it is the TS tag; compared in place with a primitive name it tests
// the exact kind. A single static type folds; a union asks a routine that cases
// on the held member, one routine per union and table.

import { Node, NodeKind, Type, TypeKind, Symbol, SymbolKind, SourceLocation, ProgramData, UnaryExprData, CallExprData, BinaryExprData, StringLiteralData, SwitchStmtData, SwitchCaseData, MatchExprData, MatchStmtData, MatchCaseData } from "../../ast/node";
import { isArrayType, unwrapRefNullUnion, peelTransparentInstance, isTagCarriedUnion, isMaybeType, isUnknownType, hasGenericParams, typeofTagOf, primitiveKindName, isPrimitiveKindName, typeofNameMatches, typeDisplayName, stringType, booleanType, nullType, setRepr, createFunction, symGenericParams, genericInstanceMembers, derivesFromClass, isAwaitable } from "../../checker/types";
import { isTypeofExpr, primitiveNameLiteral, readInStoredLayout } from "../../checker/fit";
import { declaresProperty } from "../../checker/compat";
import { hashToBase36, typeKey } from "../../codegen/c/types";
import { TransformContext, mintSym, reportTransformError } from "../context";
import { mapChildren } from "../walker";
import { makeBinary, makeBlock, makeCall, makeFnDecl, makeIf, makeReturn, makeString, makeBool, makeTypedIdentResolved, makeNull, makeUnary, callBuiltinKind } from "../util";
import { cloneIfPure } from "../place";
import { is64Kind } from "../numKinds";
import { armOrder, holdsMember } from "./unionConvLower";

let _routineSyms = new Map<string, Symbol>();
let _routineDecls: Node[] = [];

export function lowerTypeof(program: Node, ctx: TransformContext): Node {
	_routineSyms = new Map<string, Symbol>();
	_routineDecls = [];
	const result = lowerNode(program, ctx);
	if (_routineDecls.length > 0 && result.kind == NodeKind.Program) {
		for (const decl of _routineDecls) (result.data as ProgramData).programStmts.push(decl);
	}
	_routineSyms = new Map<string, Symbol>();
	_routineDecls = [];
	return result;
}

function lowerNode(node: Node, ctx: TransformContext): Node {
	if (node == null) return node;
	match (node.kind) {
		NodeKind.SwitchStmt => {
			lowerSwitchOnKind(node.data as SwitchStmtData, ctx);
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			d.matchDisc = lowerArmsOnKind(d.matchDisc, d.matchCases, ctx);
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			d.matchStmtDisc = lowerArmsOnKind(d.matchStmtDisc, d.matchStmtCases, ctx);
		},
		NodeKind.CallExpr => {
			const asked = lowerHoldsArray(node, ctx);
			if (asked != null) return asked;
		},
		NodeKind.BinaryExpr => {
			const test = lowerKindTest(node, ctx);
			if (test != null) return test;
			const instance = lowerGenericInstanceof(node, ctx);
			if (instance != null) return instance;
			const named = lowerInKeyword(node, ctx);
			if (named != null) return named;
		},
		_ => {},
	};
	mapChildren(node, (c: Node): Node => lowerNode(c, ctx));
	if (isTypeofExpr(node)) return lowerTagRead(node, ctx);
	return node;
}

enum Shape {
	Single,
	Union,
	Nullable,
	Opaque,
}

function shapeOf(t: Type | null): Shape {
	if (t == null) return Shape.Opaque;
	const v = peelTransparentInstance(t);
	if (isMaybeType(v)) return shapeOf(v.typeReturn) == Shape.Single ? Shape.Nullable : Shape.Opaque;
	if (isUnknownType(v) || hasGenericParams(v)) return Shape.Opaque;
	if (v.kind == TypeKind.GenericParam || v.kind == TypeKind.Inferred || v.kind == TypeKind.Error) return Shape.Opaque;
	return isTagCarriedUnion(v) ? Shape.Union : Shape.Single;
}

function kindNameOf(t: Type): string {
	const name = primitiveKindName(t);
	return name != "" ? name : typeofTagOf(t);
}

function operandOf(typeofNode: Node): Node {
	return (typeofNode.data as UnaryExprData).operand;
}

function opaqueKindTest(operand: Node, name: string, ctx: TransformContext, loc: SourceLocation): void {
	const t = operand.nodeType != null ? typeDisplayName(operand.nodeType) : "unknown";
	reportTransformError(ctx, `typeof of a '${t}' value carries no exact kind to compare with '${name}'; narrow it to a concrete type or a union of them first`, loc);
}

// `typeof x === "uint8"`, either side, any of the four equality operators.
function lowerKindTest(node: Node, ctx: TransformContext): Node | null {
	const d = node.data as BinaryExprData;
	const op = d.operator;
	if (op != "===" && op != "==" && op != "!==" && op != "!=") return null;
	let typeofSide = d.left;
	let name = primitiveNameLiteral(d.right);
	if (!isTypeofExpr(typeofSide) || name == "") {
		typeofSide = d.right;
		name = primitiveNameLiteral(d.left);
	}
	if (!isTypeofExpr(typeofSide) || name == "") return null;
	const negated = op == "!==" || op == "!=";
	const operand = lowerNode(operandOf(typeofSide), ctx);
	const t = operand.nodeType;
	if (t == null) {
		opaqueKindTest(operand, name, ctx, node.location);
		return node;
	}
	const shape = shapeOf(t);
	if (shape == Shape.Single) return makeBool(typeofNameMatches(t, name) != negated, node.location);
	if (shape == Shape.Opaque) {
		opaqueKindTest(operand, name, ctx, node.location);
		return node;
	}
	const op2 = negated ? "!==" : "===";
	const members = kindsOf(t);
	const tag = tagOfKind(members, name);
	if (tag == null) return makeBool(negated, node.location);
	if (tagIsUnique(members, tag)) {
		const tagRead = makeUnary("typeof", operand, node.location);
		tagRead.nodeType = stringType();
		return makeBinary(lowerTagRead(tagRead, ctx), op2, makeString(tag, node.location), node.location);
	}
	const source: Type = t;
	const kindRead = routineCall("msTypeofKind_", operand, ctx, node.location, (x: Symbol): Node[] => memberCases(source, x, kindNameOf, ctx, node.location));
	return makeBinary(kindRead, op2, makeString(name, node.location), node.location);
}

function lowerHoldsArray(node: Node, ctx: TransformContext): Node | null {
	if (callBuiltinKind(node) != "HoldsArray") return null;
	const args = (node.data as CallExprData).arguments;
	const operand = lowerNode(args[0], ctx);
	const t = operand.nodeType;
	const loc = node.location;
	const peeled = t != null ? peelTransparentInstance(t) : null;
	const payload = peeled != null && isMaybeType(peeled) && peeled.typeReturn != null ? peelTransparentInstance(peeled.typeReturn) : peeled;
	if (isUnknownType(payload)) {
		if (cloneIfPure(operand) != null || isLiteral(operand)) return makeBool(false, loc);
		return routineCall("msHoldsArray_", operand, ctx, loc, (x: Symbol): Node[] => [makeReturn(makeBool(false, loc), loc)], booleanType());
	}
	if (peeled != null && isMaybeType(peeled) && peeled.typeReturn != null && shapeOf(peeled.typeReturn) == Shape.Union) {
		const inner: Type = peeled.typeReturn;
		const whole: Type = t!;
		return routineCall("msHoldsArray_", operand, ctx, loc, (x: Symbol): Node[] => {
			const absent = makeBinary(makeTypedIdentResolved(x, whole, loc), "===", makeNull(loc), loc);
			const member = routineCall("msHoldsArray_", makeTypedIdentResolved(x, inner, loc), ctx, loc, (m: Symbol): Node[] => memberAnswers(peelTransparentInstance(inner), m, (k: Type): Node => makeBool(isArrayType(k), loc), ctx, loc), booleanType());
			return [makeIf(absent, makeBlock([makeReturn(makeBool(false, loc), loc)], loc), null, loc), makeReturn(member, loc)];
		}, booleanType());
	}
	if (t == null || shapeOf(t) == Shape.Opaque) {
		reportTransformError(ctx, `Array.isArray of a '${t != null ? typeDisplayName(t) : "unknown"}' value cannot tell an array from another value; narrow it to a concrete type or a union of them first`, loc);
		return node;
	}
	const source: Type = t;
	const held = kindsOf(source);
	if (shapeOf(source) == Shape.Single) {
		const answer = isArrayType(held[0]);
		if (cloneIfPure(operand) != null || isLiteral(operand)) return makeBool(answer, loc);
		return routineCall("msHoldsArray_", operand, ctx, loc, (x: Symbol): Node[] => [makeReturn(makeBool(answer, loc), loc)], booleanType());
	}
	return routineCall("msHoldsArray_", operand, ctx, loc, (x: Symbol): Node[] => {
		const payload = shapeOf(source) == Shape.Nullable ? held[0] : unwrapRefNullUnion(peelTransparentInstance(source));
		if (payload != null) {
			const present = makeBinary(makeTypedIdentResolved(x, source, loc), "!==", makeNull(loc), loc);
			return [makeIf(present, makeBlock([makeReturn(makeBool(isArrayType(payload), loc), loc)], loc), null, loc), makeReturn(makeBool(false, loc), loc)];
		}
		return memberAnswers(peelTransparentInstance(source), x, (member: Type): Node => makeBool(isArrayType(member), loc), ctx, loc);
	}, booleanType());
}

// `x instanceof Box` with a generic `Box` asks which union member `x` holds:
// each instance has its own identity, and the members name the instances.
function lowerGenericInstanceof(node: Node, ctx: TransformContext): Node | null {
	const d = node.data as BinaryExprData;
	const cls = d.operator == "instanceof" && d.right != null ? d.right.resolvedSym : null;
	if (cls == null || cls.symbolKind != SymbolKind.Class || symGenericParams(cls) == "") return null;
	const operand = lowerNode(d.left, ctx);
	const t = operand.nodeType;
	const u = t != null ? peelTransparentInstance(t) : null;
	if (u == null || shapeOf(u) != Shape.Union || !instanceTestable(u, cls)) {
		reportTransformError(ctx, `instanceof cannot test the generic class ${cls.name} on a '${t != null ? typeDisplayName(t) : "unknown"}' value: no union member names the instance`, node.location);
		return node;
	}
	const loc = node.location;
	if (ctx.raiserBackend && holdsAwaitable(u)) {
		reportTransformError(ctx, `instanceof cannot test a '${typeDisplayName(u)}' value on the Raiser VM: a finished Promise is read as its value there, so its member cannot be told apart`, loc);
		return node;
	}
	const held: Type = u;
	const target: Symbol = cls;
	const prefix = "msInstanceOf_" + hashToBase36(typeKey(cls.symbolType)) + "_";
	return routineCall(prefix, operand, ctx, loc, (x: Symbol): Node[] => memberAnswers(held, x, (member: Type): Node => makeBool(derivesFromClass(member, target), loc), ctx, loc), booleanType());
}

// `"name" in u` over a union asks which member `u` holds: a member that
// declares `name` as a field, optional or not, a method or an accessor answers true.
function lowerInKeyword(node: Node, ctx: TransformContext): Node | null {
	const d = node.data as BinaryExprData;
	if (d.operator != "in" || d.right.nodeType == null) return null;
	if (shapeOf(peelTransparentInstance(d.right.nodeType)) != Shape.Union) return null;
	const u = peelTransparentInstance(readInStoredLayout(d.right, peelTransparentInstance(d.right.nodeType)));
	const loc = node.location;
	if (d.left.kind != NodeKind.StringLiteral) {
		reportTransformError(ctx, `'in' on a '${typeDisplayName(u)}' value needs a string literal on the left, to know which members declare the property`, loc);
		return node;
	}
	const name = (d.left.data as StringLiteralData).value;
	const operand = lowerNode(d.right, ctx);
	const held: Type = u;
	return routineCall("msIn_" + hashToBase36(name) + "_", operand, ctx, loc, (x: Symbol): Node[] => memberAnswers(held, x, (member: Type): Node => makeBool(declaresProperty(peelTransparentInstance(member), name), loc), ctx, loc), booleanType());
}

function holdsAwaitable(u: Type): boolean {
	for (const m of u.typeChildren) if (isAwaitable(m)) return true;
	return false;
}

// An instance of `cls` cannot hide behind an ancestor member; a union with no
// member of `cls` at all answers false.
function instanceTestable(u: Type, cls: Symbol): boolean {
	if (genericInstanceMembers(u, cls) != null) return true;
	for (const m of u.typeChildren) if (derivesFromClass(m, cls)) return false;
	return true;
}

function tagOfKind(members: Type[], name: string): string | null {
	let tag: string | null = null;
	for (const m of members) {
		if (primitiveKindName(m) == name) tag = typeofTagOf(m);
	}
	return tag;
}

function tagIsUnique(members: Type[], tag: string): boolean {
	let sharing = 0;
	for (const m of members) {
		if (typeofTagOf(m) == tag) sharing += 1;
	}
	return sharing == 1;
}

// A switch or match over `typeof x` naming a primitive kind dispatches on the
// held kind's name; a TS tag case also takes every kind name it covers.
function lowerSwitchOnKind(d: SwitchStmtData, ctx: TransformContext): void {
	if (!isTypeofExpr(d.switchDisc) || !testsNameKind(d.switchCases.map((c: Node): Node[] => (c.data as SwitchCaseData).caseTests))) return;
	const kinds = operandKinds(d.switchDisc);
	const seen: string[] = [];
	for (const c of d.switchCases) {
		const cd = c.data as SwitchCaseData;
		cd.caseTests = expandTagTests(cd.caseTests, kinds, seen, true);
	}
	d.switchDisc = kindNameRead(operandOf(d.switchDisc), d.switchDisc, ctx);
}

function operandKinds(typeofNode: Node): Type[] {
	const t = operandOf(typeofNode).nodeType;
	return t != null ? kindsOf(t) : [];
}

function lowerArmsOnKind(disc: Node, cases: Node[], ctx: TransformContext): Node {
	if (!isTypeofExpr(disc) || !testsNameKind(cases.map((c: Node): Node[] => (c.data as MatchCaseData).casePatterns))) return disc;
	const kinds = operandKinds(disc);
	const seen: string[] = [];
	for (const c of cases) {
		const cd = c.data as MatchCaseData;
		cd.casePatterns = expandTagTests(cd.casePatterns, kinds, seen, cd.caseGuard == null);
	}
	return kindNameRead(operandOf(disc), disc, ctx);
}

function testsNameKind(groups: Node[][]): boolean {
	for (const tests of groups) {
		for (const t of tests) {
			if (primitiveNameLiteral(t) != "") return true;
		}
	}
	return false;
}

function kindsOf(t: Type): Type[] {
	const v = peelTransparentInstance(t);
	return match (shapeOf(v)) {
		Shape.Union => v.typeChildren,
		Shape.Nullable => {
			const inner = v.typeReturn;
			if (inner == null) throw new Error(`internal: the nullable '${typeDisplayName(v)}' has no inner type`);
			return [inner, nullType()];
		},
		_ => [v],
	};
}

function expandTagTests(tests: Node[], kinds: Type[], seen: string[], claims: boolean): Node[] {
	const out: Node[] = [];
	for (const test of tests) {
		out.push(test);
		if (test.kind != NodeKind.StringLiteral) continue;
		const tag = (test.data as StringLiteralData).value;
		const added: string[] = [];
		if (!isPrimitiveKindName(tag)) {
			for (const k of kinds) {
				const name = primitiveKindName(k);
				if (name == "" || typeofTagOf(k) != tag || seen.indexOf(name) >= 0 || added.indexOf(name) >= 0) continue;
				added.push(name);
				const lit = makeString(name, test.location);
				lit.nodeType = test.nodeType;
				out.push(lit);
			}
		}
		if (claims) {
			seen.push(tag);
			for (const name of added) seen.push(name);
		}
	}
	return out;
}

function kindNameRead(operand: Node, typeofNode: Node, ctx: TransformContext): Node {
	const lowered = lowerNode(operand, ctx);
	const t = lowered.nodeType;
	if (t == null) {
		opaqueKindTest(lowered, "a primitive name", ctx, typeofNode.location);
		return typeofNode;
	}
	const source: Type = t;
	return match (shapeOf(source)) {
		Shape.Single => tagLiteral(kindNameOf(source), typeofNode),
		Shape.Union | Shape.Nullable => routineCall("msTypeofKind_", lowered, ctx, typeofNode.location, (x: Symbol): Node[] => memberCases(source, x, kindNameOf, ctx, typeofNode.location)),
		Shape.Opaque => {
			opaqueKindTest(lowered, "a primitive name", ctx, typeofNode.location);
			return typeofNode;
		},
	};
}

// `typeof x` as a string: the TS tag. A single static type folds, evaluating
// an operand that can call through a routine. Over a union, C and the Raiser
// case on the held member already; JS's own typeof agrees with the table except
// for a 64-bit integer, which it calls "bigint".
function lowerTagRead(node: Node, ctx: TransformContext): Node {
	const operand = operandOf(node);
	const t = operand.nodeType;
	if (t == null) return node;
	const source: Type = t;
	const shape = shapeOf(source);
	const loc = node.location;
	if (shape == Shape.Single) {
		if (cloneIfPure(operand) != null || isLiteral(operand)) return tagLiteral(typeofTagOf(source), node);
		return routineCall("msTypeofTag_", operand, ctx, loc, (x: Symbol): Node[] => [makeReturn(makeString(typeofTagOf(source), loc), loc)]);
	}
	if (!ctx.jsBackend) return node;
	const peeled = peelTransparentInstance(source);
	const nullableUnion = shape == Shape.Opaque && isMaybeType(peeled) && peeled.typeReturn != null && shapeOf(peeled.typeReturn) == Shape.Union;
	if (shape == Shape.Opaque && !nullableUnion) return node;
	const members = nullableUnion ? peelTransparentInstance(peeled.typeReturn).typeChildren : kindsOf(source);
	let wide = false;
	let big = false;
	for (const m of members) {
		if (isWideInteger(m)) wide = true;
		if (peelTransparentInstance(m).kind == TypeKind.BigInt) big = true;
	}
	if (!wide) return node;
	if (big && nullableUnion) {
		const held: Type = peeled.typeReturn;
		return routineCall("msTypeofTag_", operand, ctx, loc, (x: Symbol): Node[] => {
			const absent = makeBinary(makeTypedIdentResolved(x, source, loc), "===", makeNull(loc), loc);
			const member = routineCall("msTypeofTag_", makeTypedIdentResolved(x, held, loc), ctx, loc, (m: Symbol): Node[] => memberCases(held, m, typeofTagOf, ctx, loc));
			return [makeIf(absent, makeBlock([makeReturn(makeString(typeofTagOf(nullType()), loc), loc)], loc), null, loc), makeReturn(member, loc)];
		});
	}
	if (big) {
		return routineCall("msTypeofTag_", operand, ctx, loc, (x: Symbol): Node[] => memberCases(source, x, typeofTagOf, ctx, loc));
	}
	return routineCall("msTypeofJsTag_", operand, ctx, loc, (x: Symbol): Node[] => {
		const isBig = makeBinary(rawTypeof(x, source, loc), "===", makeString("bigint", loc), loc);
		return [makeIf(isBig, makeBlock([makeReturn(makeString("number", loc), loc)], loc), null, loc), makeReturn(rawTypeof(x, source, loc), loc)];
	});
}

function isWideInteger(m: Type): boolean {
	const v = peelTransparentInstance(m);
	const repr = v.kind == TypeKind.Set ? setRepr(v) : v;
	return repr != null && is64Kind(repr.kind);
}

function rawTypeof(x: Symbol, t: Type, loc: SourceLocation): Node {
	const read = makeUnary("typeof", makeTypedIdentResolved(x, t, loc), loc);
	read.nodeType = stringType();
	return read;
}

function isLiteral(n: Node): boolean {
	return n.kind == NodeKind.StringLiteral || n.kind == NodeKind.NumberLiteral || n.kind == NodeKind.BooleanLiteral || n.kind == NodeKind.NullLiteral;
}

function tagLiteral(tag: string, typeofNode: Node): Node {
	const lit = makeString(tag, typeofNode.location);
	lit.nodeType = stringType();
	return lit;
}

function routineCall(prefix: string, operand: Node, ctx: TransformContext, loc: SourceLocation, body: (x: Symbol) => Node[], returns: Type = stringType()): Node {
	const source = operand.nodeType;
	if (source == null) throw new Error(`internal: the typeof routine '${prefix}' is called on an operand with no type`);
	const call = makeCall(makeTypedIdentResolved(nameRoutine(prefix, source, body, returns, ctx, loc), null, loc), [operand], loc);
	call.nodeType = returns;
	return call;
}

// The held member's name: a nullable asks presence, a union cases on its member.
function memberCases(source: Type, x: Symbol, nameOf: (t: Type) => string, ctx: TransformContext, loc: SourceLocation): Node[] {
	const members = kindsOf(source);
	if (shapeOf(source) == Shape.Nullable) {
		const present = makeBinary(makeTypedIdentResolved(x, source, loc), "!==", makeNull(loc), loc);
		return [
			makeIf(present, makeBlock([makeReturn(makeString(nameOf(members[0]), loc), loc)], loc), null, loc),
			makeReturn(makeString(nameOf(members[1]), loc), loc),
		];
	}
	return memberAnswers(peelTransparentInstance(source), x, (member: Type): Node => makeString(nameOf(member), loc), ctx, loc);
}

// Returns each member's answer in arm order, guarded by holding that member; the last arm is unguarded.
function memberAnswers(u: Type, x: Symbol, answerOf: (member: Type) => Node, ctx: TransformContext, loc: SourceLocation): Node[] {
	const order = armOrder(u, ctx, loc);
	const body: Node[] = [];
	for (let k = 0; k < order.length; k += 1) {
		const answer = makeReturn(answerOf(u.typeChildren[order[k]]), loc);
		if (k == order.length - 1) {
			body.push(answer);
		} else {
			body.push(makeIf(holdsMember(u, x, order[k], ctx, loc), makeBlock([answer], loc), null, loc));
		}
	}
	return body;
}

function nameRoutine(prefix: string, source: Type, buildBody: (x: Symbol) => Node[], returns: Type, ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = prefix + hashToBase36(typeKey(source));
	const known = _routineSyms.get(name);
	if (known != null) return known;
	const sym = mintSym(ctx, SymbolKind.Function, name, null);
	_routineSyms.set(name, sym);
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", source);
	const fnNode = makeFnDecl(name, [valueSym], ["unknown"], makeBlock(buildBody(valueSym), loc), "", typeDisplayName(returns), loc);
	const fnType = createFunction([source], [valueSym.name], returns);
	fnNode.nodeType = fnType;
	sym.symbolType = fnType;
	fnNode.resolvedSym = sym;
	_routineDecls.push(fnNode);
	return sym;
}
