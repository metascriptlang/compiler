import {
	Node, NodeKind, NodeFlag, Symbol, SymbolKind, SymbolState, Type,
	ProgramData, WhileStmtData, DoWhileStmtData, ForStmtData,
	ForOfStmtData, ForInStmtData, TryCatchStmtData, VariableDeclData, DestructuringDeclData,
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData, SpreadExprData, MatchCaseData,
	IdentifierData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { inferredType } from "./types";
import { makeSymbol, initSymbol, lookupSymbol } from "./symbol";
import { CheckerContext } from "./context";

class BindScope {
	names: Map<string, Symbol> = new Map<string, Symbol>();
}

class NameBinder {
	ctx: CheckerContext;
	scopes: BindScope[] = [];
	keys: Node[] = [];

	constructor(ctx: CheckerContext) {
		this.ctx = ctx;
	}
}

function openBindScope(b: NameBinder): void {
	b.scopes.push(new BindScope());
}

function closeBindScope(b: NameBinder): void {
	b.scopes.pop();
}

function declareName(b: NameBinder, name: string, kind: SymbolKind, key: Node): Symbol | null {
	if (b.scopes.length == 0) return null;
	const scope = b.scopes[b.scopes.length - 1];
	if (scope.names.has(name)) return null;
	const sym = makeSymbol(name, kind, inferredType(), true);
	scope.names.set(name, sym);
	b.ctx.adoptedDecls.set(key, sym);
	b.keys.push(key);
	return sym;
}

function lookupBound(b: NameBinder, name: string): Symbol | null {
	let i = b.scopes.length - 1;
	while (i >= 0) {
		const sym = b.scopes[i].names.get(name);
		if (sym != null) return sym;
		i -= 1;
	}
	return null;
}

function bindIdentifier(b: NameBinder, node: Node): void {
	if (node.flags.has(NodeFlag.BoundSym)) return;
	if (node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.EnumMember) return;
	const name = (node.data as IdentifierData).name;
	const local = lookupBound(b, name);
	if (local != null) {
		node.resolvedSym = local;
		b.ctx.boundIdents.set(node, local);
		b.keys.push(node);
		return;
	}
	const outer = lookupSymbol(b.ctx.table, name);
	if (outer != null && (outer.symbolKind == SymbolKind.Variable || outer.symbolKind == SymbolKind.Parameter)) {
		node.resolvedSym = outer;
	} else if (node.resolvedSym != null
			&& (node.resolvedSym.symbolKind == SymbolKind.Variable || node.resolvedSym.symbolKind == SymbolKind.Parameter)) {
		node.resolvedSym = null;
	}
}

function bindPatternElement(b: NameBinder, elem: Node, skipUnderscore: boolean): void {
	if (elem.kind != NodeKind.Identifier) return;
	const name = (elem.data as IdentifierData).name;
	if (skipUnderscore && name == "_") return;
	declareName(b, name, SymbolKind.Variable, elem);
}

function bindPattern(b: NameBinder, pattern: Node): void {
	if (pattern.kind == NodeKind.ArrayPattern) {
		const apd = pattern.data as ArrayPatternData;
		let i = 0;
		while (i < apd.patternElements.length) {
			const elem = apd.patternElements[i];
			if (i < apd.patternDefaults.length && apd.patternDefaults[i] != null) bindNode(b, apd.patternDefaults[i]);
			if (elem.kind == NodeKind.SpreadExpr) {
				bindPatternElement(b, (elem.data as SpreadExprData).spreadArg, true);
			} else {
				bindPatternElement(b, elem, true);
			}
			i += 1;
		}
	} else if (pattern.kind == NodeKind.ObjectPattern) {
		const opd = pattern.data as ObjectPatternData;
		for (const prop of opd.patternProps) {
			if (prop.kind == NodeKind.SpreadExpr) {
				bindPatternElement(b, (prop.data as SpreadExprData).spreadArg, true);
			} else if (prop.kind == NodeKind.ObjectPatternProp) {
				const p = prop.data as ObjectPatternPropData;
				if (p.propDefault != null) bindNode(b, p.propDefault);
				if (p.propAlias != null) bindPatternElement(b, p.propAlias, false);
			}
		}
	}
}

function bindBlockLike(b: NameBinder, node: Node): void {
	openBindScope(b);
	forEachChild(node, (child: Node): void => { bindNode(b, child); });
	closeBindScope(b);
}

function bindNode(b: NameBinder, node: Node): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Identifier => bindIdentifier(b, node),
		NodeKind.BlockStmt => bindBlockLike(b, node),
		NodeKind.FunctionDecl | NodeKind.MethodDecl | NodeKind.ConstructorDecl
		| NodeKind.ArrowFunction | NodeKind.FunctionExpr | NodeKind.ClassDecl | NodeKind.ActorDecl
		| NodeKind.MacroDecl | NodeKind.QuoteExpr | NodeKind.ComptimeBlock => {},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			bindNode(b, d.initializer);
			if (b.scopes.length > 0) declareName(b, d.declName, SymbolKind.Variable, node);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			bindNode(b, d.destrInit);
			bindPattern(b, d.destrPattern);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			bindNode(b, d.forOfIterable);
			openBindScope(b);
			if (d.forOfPattern != null) {
				bindPattern(b, d.forOfPattern);
			} else {
				declareName(b, d.forOfBinding, SymbolKind.Variable, node);
			}
			bindNode(b, d.forOfBody);
			closeBindScope(b);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			bindNode(b, d.forInObject);
			openBindScope(b);
			declareName(b, d.forInBinding, SymbolKind.Variable, node);
			bindNode(b, d.forInBody);
			closeBindScope(b);
		},
		NodeKind.ForStmt | NodeKind.WhileStmt | NodeKind.DoWhileStmt => bindLoop(b, node),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			bindNode(b, d.tryBody);
			if (d.catchBody != null) {
				openBindScope(b);
				if (d.catchName != "") declareName(b, d.catchName, SymbolKind.Variable, node);
				bindNode(b, d.catchBody);
				closeBindScope(b);
			}
			bindNode(b, d.finallyBody);
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			for (const p of d.casePatterns) {
				if (p.kind != NodeKind.Identifier) bindNode(b, p);
			}
			if (d.caseGuard != null) bindNode(b, d.caseGuard);
			bindNode(b, d.caseBody);
		},
		_ => forEachChild(node, (child: Node): void => { bindNode(b, child); }),
	};
}

function bindLoop(b: NameBinder, node: Node): void {
	if (node.kind == NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		bindNode(b, d.whileCondition);
		openBindScope(b);
		bindNode(b, d.whileBody);
		closeBindScope(b);
	} else if (node.kind == NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		openBindScope(b);
		bindNode(b, d.doBody);
		closeBindScope(b);
		bindNode(b, d.doCondition);
	} else {
		const d = node.data as ForStmtData;
		openBindScope(b);
		bindNode(b, d.forInit);
		bindNode(b, d.forCondition);
		bindNode(b, d.forUpdate);
		bindNode(b, d.forBody);
		closeBindScope(b);
	}
}

function newBinder(ctx: CheckerContext): NameBinder {
	return new NameBinder(ctx);
}

export function bindContainerNames(ctx: CheckerContext, params: string[], body: Node): Node[] {
	const b = newBinder(ctx);
	openBindScope(b);
	const paramSyms: Symbol[] = [];
	for (const p of params) {
		const sym = makeSymbol(p, SymbolKind.Parameter, inferredType(), false);
		paramSyms.push(sym);
		const scope = b.scopes[0];
		if (!scope.names.has(p)) scope.names.set(p, sym);
	}
	ctx.adoptedParams.set(body, paramSyms);
	b.keys.push(body);
	bindNode(b, body);
	return b.keys;
}

export function bindModuleNames(ctx: CheckerContext, program: Node): Node[] {
	const b = newBinder(ctx);
	const d = program.data as ProgramData;
	for (const stmt of d.programStmts) bindNode(b, stmt);
	return b.keys;
}

export function releaseNames(ctx: CheckerContext, keys: Node[]): void {
	for (const key of keys) {
		ctx.adoptedDecls.delete(key);
		ctx.adoptedParams.delete(key);
		ctx.boundIdents.delete(key);
	}
}

export function paramSymbol(ctx: CheckerContext, body: Node, index: int32, name: string, kind: SymbolKind, symType: Type | null): Symbol {
	const bound = ctx.adoptedParams.get(body);
	if (bound == null || index >= bound.length) return makeSymbol(name, kind, symType, false);
	const sym = bound[index];
	initSymbol(sym, name, kind, symType, false, SymbolState.Hollow);
	return sym;
}
