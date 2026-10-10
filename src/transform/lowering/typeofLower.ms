// `typeof x` reads the compiler's tag table on every backend (CK-181). Converted
// to a string it is the TS tag; compared in place with a primitive name it tests
// the exact kind. A single static type folds; a union asks a routine that cases
// on the held member, one routine per union and table.

import { Node, NodeKind, Type, TypeKind, Symbol, SymbolKind, SourceLocation, ProgramData, UnaryExprData, BinaryExprData, StringLiteralData, SwitchStmtData, SwitchCaseData, MatchExprData, MatchStmtData, MatchCaseData } from "../../ast/node";
import { peelTransparentInstance, isTagCarriedUnion, isMaybeType, isUnknownType, hasGenericParams, typeofTagOf, primitiveKindName, isPrimitiveKindName, typeofNameMatches, typeDisplayName, stringType, nullType, setRepr } from "../../checker/types";
import { isTypeofExpr, primitiveNameLiteral } from "../../checker/fit";
import { hashToBase36, typeKey } from "../../codegen/c/types";
import { TransformContext, mintSym, reportTransformError } from "../context";
import { mapChildren } from "../walker";
import { makeBinary, makeBlock, makeCall, makeFnDecl, makeIf, makeReturn, makeString, makeBool, makeTypedIdentResolved, makeNull, makeUnary } from "../util";
import { cloneIfPure } from "../coercion/intArithJS";
import { armOrder, holdsMember } from "./unionConvLower";

let _routineNames: string[] = [];
let _routineSyms: Symbol[] = [];
let _routineDecls: Node[] = [];

export function lowerTypeof(program: Node, ctx: TransformContext): Node {
	_routineNames = [];
	_routineSyms = [];
	_routineDecls = [];
	const result = lowerNode(program, ctx);
	if (_routineDecls.length > 0 && result.kind == NodeKind.Program) {
		for (const decl of _routineDecls) (result.data as ProgramData).programStmts.push(decl);
	}
	_routineNames = [];
	_routineSyms = [];
	_routineDecls = [];
	return result;
}

function lowerNode(node: Node, ctx: TransformContext): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.SwitchStmt) lowerSwitchOnKind(node.data as SwitchStmtData, ctx);
	if (node.kind == NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		d.matchDisc = lowerArmsOnKind(d.matchDisc, d.matchCases, ctx);
	}
	if (node.kind == NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		d.matchStmtDisc = lowerArmsOnKind(d.matchStmtDisc, d.matchStmtCases, ctx);
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const test = lowerKindTest(node, ctx);
		if (test != null) return test;
	}
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
	const shape = shapeOf(t);
	if (shape == Shape.Single) return makeBool(typeofNameMatches(t!, name) != negated, node.location);
	if (shape == Shape.Opaque) {
		opaqueKindTest(operand, name, ctx, node.location);
		return node;
	}
	const op2 = negated ? "!==" : "===";
	const tag = heldTagOf(kindsOf(t!), name);
	if (tag == null) return makeBool(negated, node.location);
	if (tag != "") {
		const tagRead = makeUnary("typeof", operand, node.location);
		tagRead.nodeType = stringType();
		return makeBinary(lowerTagRead(tagRead, ctx), op2, makeString(tag, node.location), node.location);
	}
	const kindRead = routineCall("msTypeofKind_", operand, ctx, node.location, (x: Symbol): Node[] => memberCases(t!, x, kindNameOf, ctx, node.location));
	return makeBinary(kindRead, op2, makeString(name, node.location), node.location);
}

// The TS tag that alone tells the member of kind `name` apart: null when no
// member has that kind, "" when another member shares its tag.
function heldTagOf(members: Type[], name: string): string | null {
	let tag: string | null = null;
	for (const m of members) {
		if (primitiveKindName(m) == name) tag = typeofTagOf(m);
	}
	if (tag == null) return null;
	let sharing = 0;
	for (const m of members) {
		if (typeofTagOf(m) == tag) sharing += 1;
	}
	return sharing == 1 ? tag : "";
}

// A switch or match over `typeof x` naming a primitive kind dispatches on the
// held kind's name; a TS tag case also takes every kind name it covers.
function lowerSwitchOnKind(d: SwitchStmtData, ctx: TransformContext): void {
	if (!isTypeofExpr(d.switchDisc) || !testsNameKind(d.switchCases.map((c: Node): Node[] => (c.data as SwitchCaseData).caseTests))) return;
	const kinds = operandOf(d.switchDisc).nodeType != null ? kindsOf(operandOf(d.switchDisc).nodeType!) : [];
	const seen: string[] = [];
	for (const c of d.switchCases) {
		const cd = c.data as SwitchCaseData;
		cd.caseTests = expandTagTests(cd.caseTests, kinds, seen, true);
	}
	d.switchDisc = kindNameRead(operandOf(d.switchDisc), d.switchDisc, ctx);
}

function lowerArmsOnKind(disc: Node, cases: Node[], ctx: TransformContext): Node {
	if (!isTypeofExpr(disc) || !testsNameKind(cases.map((c: Node): Node[] => (c.data as MatchCaseData).casePatterns))) return disc;
	const kinds = operandOf(disc).nodeType != null ? kindsOf(operandOf(disc).nodeType!) : [];
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
		Shape.Nullable => [v.typeReturn!, nullType()],
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
	const shape = shapeOf(lowered.nodeType);
	if (shape == Shape.Single) return tagLiteral(kindNameOf(lowered.nodeType!), typeofNode);
	if (shape != Shape.Opaque) return routineCall("msTypeofKind_", lowered, ctx, typeofNode.location, (x: Symbol): Node[] => memberCases(lowered.nodeType!, x, kindNameOf, ctx, typeofNode.location));
	opaqueKindTest(lowered, "a primitive name", ctx, typeofNode.location);
	return typeofNode;
}

// `typeof x` as a string: the TS tag. A single static type folds, evaluating
// an operand that can call through a routine. Over a union, C and the Raiser
// case on the held member already; JS's own typeof agrees with the table except
// for a 64-bit integer, which it calls "bigint".
function lowerTagRead(node: Node, ctx: TransformContext): Node {
	const operand = operandOf(node);
	const t = operand.nodeType;
	const shape = shapeOf(t);
	const loc = node.location;
	if (shape == Shape.Single) {
		if (cloneIfPure(operand) != null || isLiteral(operand)) return tagLiteral(typeofTagOf(t!), node);
		return routineCall("msTypeofTag_", operand, ctx, loc, (x: Symbol): Node[] => [makeReturn(makeString(typeofTagOf(t!), loc), loc)]);
	}
	if (shape == Shape.Opaque || !ctx.jsBackend) return node;
	const members = kindsOf(t!);
	let wide = false;
	let big = false;
	for (const m of members) {
		if (isWideInteger(m)) wide = true;
		if (peelTransparentInstance(m).kind == TypeKind.BigInt) big = true;
	}
	if (!wide) return node;
	if (big) {
		return routineCall("msTypeofTag_", operand, ctx, loc, (x: Symbol): Node[] => memberCases(t!, x, typeofTagOf, ctx, loc));
	}
	return routineCall("msTypeofJsTag_", operand, ctx, loc, (x: Symbol): Node[] => {
		const isBig = makeBinary(rawTypeof(x, t!, loc), "===", makeString("bigint", loc), loc);
		return [makeIf(isBig, makeBlock([makeReturn(makeString("number", loc), loc)], loc), null, loc), makeReturn(rawTypeof(x, t!, loc), loc)];
	});
}

function isWideInteger(m: Type): boolean {
	const v = peelTransparentInstance(m);
	const repr = v.kind == TypeKind.Set ? setRepr(v) : v;
	return repr != null && (repr.kind == TypeKind.Int64 || repr.kind == TypeKind.Uint64);
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

function routineCall(prefix: string, operand: Node, ctx: TransformContext, loc: SourceLocation, body: (x: Symbol) => Node[]): Node {
	const call = makeCall(makeTypedIdentResolved(nameRoutine(prefix, operand.nodeType!, body, ctx, loc), null, loc), [operand], loc);
	call.nodeType = stringType();
	return call;
}

// The held member's name: a nullable asks presence, a union cases on its member.
function memberCases(source: Type, x: Symbol, nameOf: (t: Type) => string, ctx: TransformContext, loc: SourceLocation): Node[] {
	const members = kindsOf(source);
	const body: Node[] = [];
	if (shapeOf(source) == Shape.Nullable) {
		const present = makeBinary(makeTypedIdentResolved(x, source, loc), "!==", makeNull(loc), loc);
		body.push(makeIf(present, makeBlock([makeReturn(makeString(nameOf(members[0]), loc), loc)], loc), null, loc));
		body.push(makeReturn(makeString(nameOf(members[1]), loc), loc));
		return body;
	}
	const u = peelTransparentInstance(source);
	const order = armOrder(u, ctx, loc);
	for (let k = 0; k < order.length; k += 1) {
		const answer = makeReturn(makeString(nameOf(u.typeChildren[order[k]]), loc), loc);
		if (k == order.length - 1) {
			body.push(answer);
		} else {
			body.push(makeIf(holdsMember(u, x, order[k], ctx, loc), makeBlock([answer], loc), null, loc));
		}
	}
	return body;
}

function nameRoutine(prefix: string, source: Type, buildBody: (x: Symbol) => Node[], ctx: TransformContext, loc: SourceLocation): Symbol {
	const name = prefix + hashToBase36(typeKey(source));
	const at = _routineNames.indexOf(name);
	if (at >= 0) return _routineSyms[at];
	const sym = mintSym(ctx, SymbolKind.Function, name, null);
	_routineNames.push(name);
	_routineSyms.push(sym);
	const valueSym = mintSym(ctx, SymbolKind.Parameter, "x", source);
	const fnNode = makeFnDecl(name, [valueSym], ["unknown"], makeBlock(buildBody(valueSym), loc), "", "string", loc);
	if (fnNode.nodeType == null || fnNode.nodeType.typeChildren == null || fnNode.nodeType.typeChildren.length != 1) {
		throw new Error(`internal: the typeof routine for '${typeDisplayName(source)}' has no parameter type`);
	}
	fnNode.nodeType.typeChildren[0] = source;
	fnNode.nodeType.typeReturn = stringType();
	sym.symbolType = fnNode.nodeType;
	fnNode.resolvedSym = sym;
	_routineDecls.push(fnNode);
	return sym;
}
