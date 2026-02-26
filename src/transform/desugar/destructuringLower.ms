// Destructuring Lowering — transforms DestructuringDecl → temp var + field access

import {
	Node, NodeKind, DeclKind,
	DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	IdentifierData,
} from "../../ast/node";
import { TransformContext, freshTemp } from "../context";
import { walkExpandBlocks } from "../walker";
import {
	makeIdent, makeVarDecl, makeNumber, makeArrayAccess, makeMember, makeCall,
} from "../util";
import { test, check, testGroup } from "std/testing";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerDestructuring(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandDestructuring, ctx);
	return program;
}

// Expand array pattern [a, b, ...rest] → indexed access
function expandArrayRet(
	pattern: Node, base: Node, declKind: DeclKind,
	loc: Node["location"], ctx: TransformContext
): Node[] {
	const apd = pattern.data as ArrayPatternData;
	const out: Node[] = [];
	let i = 0;
	while (i < apd.patternElements.length) {
		const elem = apd.patternElements[i];

		// Rest element: last + hasRestElement
		if (apd.hasRestElement && i === apd.patternElements.length - 1) {
			if (elem.kind === NodeKind.Identifier) {
				const id = elem.data as IdentifierData;
				const sliceCallee = makeMember(base, "slice", loc);
				const sliceArg = makeNumber(i, loc);
				const sliceCall = makeCall(sliceCallee, [sliceArg], loc);
				out.push(makeVarDecl(id.name, sliceCall, declKind, loc));
			}
			i += 1;
			continue;
		}

		// Simple identifier binding
		if (elem.kind === NodeKind.Identifier) {
			const id = elem.data as IdentifierData;
			if (id.name !== "_") {
				const access = makeArrayAccess(base, makeNumber(i, loc), loc);
				out.push(makeVarDecl(id.name, access, declKind, loc));
			}
		}

		i += 1;
	}
	return out;
}

// Expand object pattern {x, y: z} → member access
function expandObjectRet(
	pattern: Node, base: Node, declKind: DeclKind,
	loc: Node["location"], ctx: TransformContext
): Node[] {
	const opd = pattern.data as ObjectPatternData;
	const out: Node[] = [];
	for (const prop of opd.patternProps) {
		if (prop.kind !== NodeKind.ObjectPatternProp) continue;
		const p = prop.data as ObjectPatternPropData;
		if (p.propAlias.kind === NodeKind.Identifier) {
			const id = p.propAlias.data as IdentifierData;
			const memberAccess = makeMember(base, p.propKey, loc);
			out.push(makeVarDecl(id.name, memberAccess, declKind, loc));
		}
	}
	return out;
}

function expandDestructuring(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind !== NodeKind.DestructuringDecl) return [stmt];
	const d = stmt.data as DestructuringDeclData;
	const loc = stmt.location;
	const result: Node[] = [];

	// Simple RHS (identifier/member/access) → skip temp
	let baseExpr: Node;
	const initKind = d.destrInit.kind;
	if (initKind === NodeKind.Identifier || initKind === NodeKind.MemberExpr || initKind === NodeKind.ArrayAccess) {
		baseExpr = d.destrInit;
	} else {
		const tempName = freshTemp(ctx, "destr");
		result.push(makeVarDecl(tempName, d.destrInit, DeclKind.Const, loc));
		baseExpr = makeIdent(tempName, loc);
	}

	const dk = match (d.destrIsConst) { true => DeclKind.Const, _ => DeclKind.Let };
	if (d.destrPattern.kind === NodeKind.ArrayPattern) {
		const expanded = expandArrayRet(d.destrPattern, baseExpr, dk, loc, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}
	if (d.destrPattern.kind === NodeKind.ObjectPattern) {
		const expanded = expandObjectRet(d.destrPattern, baseExpr, dk, loc, ctx);
		for (const node of expanded) {
			result.push(node);
		}
	}

	return result;
}

// ===== Tests =====

testGroup("Destructuring Lowering", () => {
	test("array 2 elements", () => {
		check(stmtCountAfter("const [a, b] = f();", lowerDestructuring) === 3);
	});
	test("first stmt is temp VarDecl", () => {
		check(firstStmtKindAfter("const [a, b] = f();", lowerDestructuring) === NodeKind.VariableDecl);
	});
	test("object destructuring", () => {
		check(stmtCountAfter("const { x, y } = f();", lowerDestructuring) === 3);
	});
	test("simple RHS skips temp", () => {
		check(stmtCountAfter("const [a, b] = myVar;", lowerDestructuring) === 2);
	});
	test("non-destructuring passthrough", () => {
		check(stmtCountAfter("const x = 1;", lowerDestructuring) === 1);
	});
	test("preserves surrounding stmts", () => {
		check(stmtCountAfter("let z = 0; const [a, b] = f(); let w = 1;", lowerDestructuring) === 5);
	});
});
