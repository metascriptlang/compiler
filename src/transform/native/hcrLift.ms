import {
	Node, NodeKind, SourceLocation, createNode, DeclKind, SymbolKind, SymbolFlag,
	ProgramData, VariableDeclData, ExportDeclData, DecoratedDeclData, ExprStmtData,
	MacroInvocationData, Symbol, Type, TypeKind,
} from "../../ast/node";
import { createPtr, createStruct, booleanType, isUnresolvedType } from "../../checker/types";
import { makeSymbol, setFlag } from "../../checker/symbol";
import { constantLiteralOf } from "../../checker/constFold";
import { skipConvDfa } from "../../analyzer/alias";
import { hcrSignatureKey } from "../../compiler/hcrAbi";
import { mangledGlobalName } from "../../codegen/c/names";
import { cStringLiteral } from "../../codegen/c/literals";
import { TransformContext, reportTransformError } from "../context";
import { walkNode } from "../walker";
import {
	makeIdentResolved, makeHiddenDeref, makeMember, makeBinary, makeExprStmt,
	makeVarDecl, makeIf, makeBlock, syntheticToken,
} from "../util";

interface HcrGlobal {
	sym: Symbol;
	declType: Type;
	storageType: Type;
	initNode: Node;
	cName: string;
	key: string;
	pointer: Symbol;
	fresh: Symbol;
	literalAlias: boolean;
}

export function liftHcrState(program: Node, ctx: TransformContext, moduleId: string): Node {
	if (program == null || program.kind != NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const loc = program.location;
	const globals: HcrGlobal[] = [];
	const bySymbol = new HashMap<Symbol, HcrGlobal>();
	const first = makeHcrSymbol("_ms_hcr_first", booleanType());
	const firstDecl = makeHcrVariableDecl(first, loc);
	const result: Node[] = [
		makeEmitStmt("/*INCLUDESECTION*/#include \"runtime/hcr.h\"", loc),
		firstDecl,
		makeEmitStmt(`/*DATINITSECTION*/  _ms_hcr_first = msHcrModuleBegin(${cStringLiteral(moduleId)});`, loc),
	];
	const kept: Node[] = [];
	for (const stmt of pd.programStmts) {
		const g = extractGlobal(stmt, ctx, globals.length as int32);
		if (g == null) {
			kept.push(isDeclarationOrEmit(stmt)
				? stmt
				: makeIf(makeIdentResolved(first, stmt.location), makeBlock([stmt], stmt.location), null, stmt.location));
			continue;
		}
		globals.push(g);
		bySymbol.set(g.sym, g);
		result.push(hcrStorageDecl(g.storageType, stmt.location));
		result.push(makeHcrVariableDecl(g.pointer, stmt.location));
		result.push(makeHcrVariableDecl(g.fresh, stmt.location));
		result.push(makeEmitStmt(
			`/*DATINITSECTION*/  ${g.fresh.nativeName} = msHcrRegisterVariable(${cStringLiteral(moduleId)}, ${cStringLiteral(g.cName)}, ${cStringLiteral(g.key)}, sizeof(*${g.pointer.nativeName}), (void**)&${g.pointer.nativeName});`,
			stmt.location,
		));
		if (g.initNode != null) {
			const lhs = makeIdentResolved(g.sym, stmt.location);
			lhs.nodeType = g.declType;
			const assign = makeBinary(lhs, "=", g.initNode, stmt.location);
			assign.nodeType = g.declType;
			const init = makeExprStmt(assign, stmt.location);
			kept.push(g.literalAlias ? init
				: makeIf(makeIdentResolved(g.fresh, stmt.location), makeBlock([init], stmt.location), null, stmt.location));
		}
	}
	let entries = "";
	for (const g of globals) entries = entries + `${cStringLiteral(g.cName)}, ${cStringLiteral(g.key)}, `;
	result.push(makeEmitStmt(
		`MS_HCR_EXPORT const char* const* HcrVariables000(void) { static const char* const variables[] = { ${entries}NULL }; return variables; }`,
		loc,
	));
	for (const stmt of kept) result.push(rewriteGlobalRefs(stmt, bySymbol));
	pd.programStmts = result;
	return program;
}

function unwrapDeclaration(node: Node): Node {
	let n = node;
	while (n != null) {
		if (n.kind == NodeKind.ExportDecl) {
			n = (n.data as ExportDeclData).exportedDecl;
		} else if (n.kind == NodeKind.DecoratedDecl) {
			n = (n.data as DecoratedDeclData).decoratedNode;
		} else {
			return n;
		}
	}
	return null as unknown as Node;
}

function extractGlobal(stmt: Node, ctx: TransformContext, index: int32): HcrGlobal {
	const node = unwrapDeclaration(stmt);
	if (node == null || node.kind != NodeKind.VariableDecl) return null as unknown as HcrGlobal;
	const d = node.data as VariableDeclData;
	if (d.declName.length > 8 && d.declName.endsWith("TypeInfo")) return null as unknown as HcrGlobal;
	const sym = node.resolvedSym;
	if (sym == null) {
		reportTransformError(ctx, `internal: HCR state lifting met module variable '${d.declName}' without a symbol`, node.location);
		return null as unknown as HcrGlobal;
	}
	const t = node.nodeType != null ? node.nodeType : sym.symbolType;
	if (t == null || t.kind == TypeKind.None || isUnresolvedType(t)
			|| sym.symbolType == null || sym.symbolType.kind == TypeKind.None || isUnresolvedType(sym.symbolType)) {
		reportTransformError(ctx, `internal: HCR state lifting met module variable '${d.declName}' without a resolved type`, node.location);
		return null as unknown as HcrGlobal;
	}
	const storageType = createStruct(`_ms_hcr_value${index}`, ["value"], [t], true);
	const pointer = makeHcrSymbol(`_ms_hcr_v${index}`, createPtr(storageType));
	const fresh = makeHcrSymbol(`_ms_hcr_new${index}`, booleanType());
	return {
		sym, declType: t, storageType, initNode: d.initializer,
		cName: mangledGlobalName(sym, d.declName),
		key: "v:" + hcrSignatureKey(sym.symbolType),
		pointer, fresh,
		literalAlias: d.declKind == DeclKind.Const && isLiteralAlias(d.initializer),
	};
}

function isLiteralAlias(initializer: Node): boolean {
	return initializer != null && (constantLiteralOf(initializer, 0) != null || isStringLiteralAlias(initializer, 0));
}

function isStringLiteralAlias(initializer: Node, depth: int32): boolean {
	if (initializer == null || depth > 64) return false;
	const literal = skipConvDfa(initializer);
	if (literal.kind == NodeKind.StringLiteral || literal.kind == NodeKind.NullLiteral) return true;
	if (literal.kind != NodeKind.Identifier || literal.resolvedSym == null) return false;
	const sym = literal.resolvedSym;
	if (sym.symbolKind != SymbolKind.Variable || sym.symFlags.has(SymbolFlag.Mutable)) return false;
	const decl = unwrapDeclaration(sym.declNode);
	if (decl == null || decl.kind != NodeKind.VariableDecl) return false;
	const d = decl.data as VariableDeclData;
	return d.declKind == DeclKind.Const && isStringLiteralAlias(d.initializer, depth + 1);
}

function makeHcrSymbol(name: string, t: Type): Symbol {
	const sym = makeSymbol(name, SymbolKind.Variable, t, true);
	sym.nativeName = name;
	setFlag(sym, SymbolFlag.Global);
	setFlag(sym, SymbolFlag.Used);
	setFlag(sym, SymbolFlag.Cursor);
	return sym;
}


function makeHcrVariableDecl(sym: Symbol, loc: SourceLocation): Node {
	const decl = makeVarDecl(sym.name, null as unknown as Node, DeclKind.Let, loc);
	decl.resolvedSym = sym;
	decl.nodeType = sym.symbolType;
	return decl;
}

function rewriteGlobalRefs(node: Node, globals: HashMap<Symbol, HcrGlobal>): Node {
	return walkNode(node, (n: Node): Node => {
		if ((n.kind != NodeKind.Identifier && n.kind != NodeKind.MemberExpr) || n.resolvedSym == null) return n;
		const g = globals.get(n.resolvedSym);
		if (g == null) return n;
		const value = makeMember(makeHiddenDeref(makeIdentResolved(g.pointer, n.location), n.location), "value", n.location);
		value.nodeType = n.nodeType != null ? n.nodeType : g.declType;
		return value;
	});
}

export function hcrStorageDecl(t: Type, loc: SourceLocation): Node {
	const decl = createNode(NodeKind.StructDecl, {
		interfaceName: t.typeName, interfaceFields: ["value"], interfaceFieldTypes: [],
		interfaceExtends: [], nameLocation: loc,
	}, syntheticToken(loc));
	decl.nodeType = t;
	return decl;
}

function isDeclarationOrEmit(stmt: Node): boolean {
	const node = unwrapDeclaration(stmt);
	if (node == null) return true;
	match (node.kind) {
		NodeKind.VariableDecl | NodeKind.FunctionDecl | NodeKind.ImportDecl | NodeKind.TypeAliasDecl
			| NodeKind.EnumDecl | NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.ClassDecl
			| NodeKind.PropertyDecl | NodeKind.MethodDecl | NodeKind.ConstructorDecl | NodeKind.ActorDecl
			| NodeKind.ExternDecl | NodeKind.MacroDecl | NodeKind.TestDecl | NodeKind.ComptimeBlock => { return true; },
		NodeKind.ExprStmt => {
			const expr = (node.data as ExprStmtData).expr;
			return expr != null && expr.kind == NodeKind.MacroInvocation && (expr.data as MacroInvocationData).macroName == "emit";
		},
		NodeKind.MacroInvocation => { return (node.data as MacroInvocationData).macroName == "emit"; },
		_ => { return false; },
	};
}

function makeEmitStmt(code: string, loc: SourceLocation): Node {
	const strNode = createNode(NodeKind.StringLiteral, { value: code }, syntheticToken(loc));
	const macroNode = createNode(NodeKind.MacroInvocation, { macroName: "emit", macroArgs: [strNode], macroHasParens: true }, syntheticToken(loc));
	return createNode(NodeKind.ExprStmt, { expr: macroNode }, syntheticToken(loc));
}
