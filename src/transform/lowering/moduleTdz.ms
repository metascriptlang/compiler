import {
	Node, NodeKind, NodeFlag, DeclKind, Symbol, SymbolKind, SymbolFlag, ProgramData, ExportDeclData, DecoratedDeclData,
	VariableDeclData, ClassDeclData, PropertyDeclData, CallExprData, MemberExprData, NewExprData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { booleanType } from "../../checker/types";
import { makeSymbol, setFlag } from "../../checker/symbol";
import { ModuleGraph, Module } from "../../module/graph";
import { TransformContext, mintSym } from "../context";
import { makeVarDecl, makeAssign, makeExprStmt, makeIdentResolved, makeBool } from "../util";

interface ModuleBinding {
	sym: Symbol;
	statement: int32;
}

export function planModuleTdz(program: Node, ctx: TransformContext): Node {
	if (program == null || program.kind != NodeKind.Program || ctx.checkerCtx == null) return program;
	const modulePath = ctx.checkerCtx.modulePath;
	const stmts = (program.data as ProgramData).programStmts;
	const bindings: ModuleBinding[] = [];
	let firstRun = -1;
	for (let i = 0; i < stmts.length; i += 1) {
		const decl = unwrapDecl(stmts[i]);
		const sym = lexicalBindingOf(decl);
		if (sym != null) bindings.push({ sym, statement: i });
		if (firstRun < 0 && runsModuleCode(decl, modulePath)) firstRun = i;
	}
	const deferred = new HashSet<Symbol>();
	const deferredOrder: Symbol[] = [];
	for (const stmt of stmts) collectDeferredUses(stmt, false, deferred, deferredOrder);
	const self = ctx.checkerCtx.currentModule;
	const cycle = cycleOf(ctx.checkerCtx.moduleGraph, modulePath);
	const sets: Node[][] = [];
	for (let i = 0; i < stmts.length; i += 1) sets.push([]);
	const flagDecls: Node[] = [];
	for (const b of bindings) {
		const reached = deferred.has(b.sym) && (cycle.size > 0 || (firstRun >= 0 && firstRun <= b.statement));
		if (!reached && !importedByCycleMember(ctx.checkerCtx.moduleGraph, cycle, modulePath, b.sym.name)) continue;
		const flag = mintSym(ctx, SymbolKind.Variable, b.sym.name + "$init", booleanType());
		markModuleFlag(flag, modulePath);
		ctx.tdzFlags.set(b.sym, flag);
		const loc = stmts[b.statement].location;
		const decl = makeVarDecl(flag.name, makeBool(false, loc), DeclKind.Let, loc);
		decl.resolvedSym = flag;
		decl.nodeType = booleanType();
		flagDecls.push(decl);
		const target = makeIdentResolved(flag, loc);
		sets[b.statement].push(makeExprStmt(makeAssign(target, makeBool(true, loc), loc), loc));
	}
	for (const sym of deferredOrder) {
		if (sym.modulePath == "" || sym.modulePath == modulePath || !cycle.has(sym.modulePath)) continue;
		if (!isLexicalBindingSym(sym) || self == null || !importsByName(self, sym.modulePath, sym.name)) continue;
		const flag = makeSymbol(sym.name + "$init", SymbolKind.Variable, booleanType(), true);
		markModuleFlag(flag, sym.modulePath);
		ctx.tdzFlags.set(sym, flag);
	}
	if (flagDecls.length == 0) return program;
	const out: Node[] = [];
	let i = 0;
	while (i < stmts.length && stmts[i].kind == NodeKind.ImportDecl) { out.push(stmts[i]); i += 1; }
	for (const decl of flagDecls) out.push(decl);
	while (i < stmts.length) {
		out.push(stmts[i]);
		for (const set of sets[i]) out.push(set);
		i += 1;
	}
	(program.data as ProgramData).programStmts = out;
	return program;
}

function markModuleFlag(flag: Symbol, modulePath: string): void {
	flag.modulePath = modulePath;
	setFlag(flag, SymbolFlag.Global);
	setFlag(flag, SymbolFlag.Mutable);
}

function unwrapDecl(stmt: Node): Node {
	let n = stmt;
	while (n != null) {
		if (n.kind == NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
		else if (n.kind == NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
		else return n;
	}
	return stmt;
}

function lexicalBindingOf(decl: Node): Symbol | null {
	if (decl == null || decl.resolvedSym == null) return null;
	if (decl.kind == NodeKind.ClassDecl) return decl.resolvedSym;
	if (decl.kind != NodeKind.VariableDecl || decl.flags.has(NodeFlag.StaticStorage)) return null;
	const kind = (decl.data as VariableDeclData).declKind;
	return kind == DeclKind.Let || kind == DeclKind.Const ? decl.resolvedSym : null;
}

function isLexicalBindingSym(sym: Symbol): boolean {
	if (sym.symbolKind == SymbolKind.Class) return true;
	const decl = sym.declNode;
	return sym.symbolKind == SymbolKind.Variable && decl != null && decl.resolvedSym == sym && lexicalBindingOf(decl) == sym;
}

function isFunctionLike(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ArrowFunction
		|| n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ConstructorDecl;
}

function collectDeferredUses(n: Node, inFunction: boolean, uses: HashSet<Symbol>, order: Symbol[]): void {
	if (n == null) return;
	if (inFunction && n.kind == NodeKind.Identifier && n.resolvedSym != null && !uses.has(n.resolvedSym)) {
		uses.add(n.resolvedSym);
		order.push(n.resolvedSym);
	}
	const deferred = inFunction || isFunctionLike(n)
		|| (n.kind == NodeKind.PropertyDecl && !(n.data as PropertyDeclData).propIsStatic);
	forEachChild(n, (c: Node): void => collectDeferredUses(c, deferred, uses, order));
}

function isLocal(sym: Symbol | null, modulePath: string): boolean {
	return sym != null && sym.modulePath == modulePath && !sym.symFlags.has(SymbolFlag.ImportC);
}

function runsModuleCode(decl: Node, modulePath: string): boolean {
	if (decl == null) return false;
	match (decl.kind) {
		NodeKind.FunctionDecl | NodeKind.ImportDecl | NodeKind.TypeAliasDecl | NodeKind.InterfaceDecl
			| NodeKind.EnumDecl | NodeKind.StructDecl | NodeKind.ExternDecl | NodeKind.MacroDecl | NodeKind.TestDecl => { return false; },
		NodeKind.ClassDecl => {
			for (const member of (decl.data as ClassDeclData).classBody) {
				if (member.kind == NodeKind.PropertyDecl && (member.data as PropertyDeclData).propIsStatic
					&& reachesLocalCode((member.data as PropertyDeclData).propInitializer, modulePath)) return true;
			}
			return false;
		},
		_ => { return reachesLocalCode(decl, modulePath); },
	};
}

function reachesLocalCode(n: Node, modulePath: string): boolean {
	if (n == null) return false;
	if (n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ArrowFunction) return true;
	if (n.kind == NodeKind.Identifier && n.resolvedSym != null && n.resolvedSym.symbolKind == SymbolKind.Function
		&& isLocal(n.resolvedSym, modulePath)) return true;
	if (n.kind == NodeKind.NewExpr && isLocal((n.data as NewExprData).newCallee.resolvedSym, modulePath)) return true;
	if (n.kind == NodeKind.CallExpr) {
		const callee = (n.data as CallExprData).callee;
		if (isLocal(n.resolvedSym, modulePath) || isLocal(callee.resolvedSym, modulePath)) return true;
		if (callee.kind == NodeKind.MemberExpr) {
			const receiver = (callee.data as MemberExprData).object;
			if (isLocal(receiver.resolvedSym, modulePath) && receiver.resolvedSym.symbolKind != SymbolKind.Module) return true;
		} else if (callee.kind != NodeKind.Identifier) {
			return true;
		}
	}
	let found = false;
	forEachChild(n, (c: Node): void => { if (!found && reachesLocalCode(c, modulePath)) found = true; });
	return found;
}

function importsByName(mod: Module, from: string, name: string): boolean {
	for (const entry of mod.imports) {
		if (entry.sourcePath == from && entry.names.indexOf(name) >= 0) return true;
	}
	return false;
}

function importedByCycleMember(graph: ModuleGraph | null, cycle: HashSet<string>, modulePath: string, name: string): boolean {
	if (graph == null) return false;
	for (const mod of graph.modules) {
		if (mod.path != modulePath && cycle.has(mod.path) && importsByName(mod, modulePath, name)) return true;
	}
	return false;
}

let _cycleGraph: ModuleGraph | null = null;
let _cycleModules = 0;
let _cycles = new HashMap<string, HashSet<string>>();

function cycleOf(graph: ModuleGraph | null, modulePath: string): HashSet<string> {
	if (graph == null) return new HashSet<string>();
	if (_cycleGraph != graph || _cycleModules != graph.modules.length) {
		_cycleGraph = graph;
		_cycleModules = graph.modules.length;
		const walk: SccWalk = { graph, index: new HashMap<string, int32>(), low: new HashMap<string, int32>(), onStack: new HashSet<string>(), stack: [], counter: 0, cycles: new HashMap<string, HashSet<string>>() };
		for (const path of graph.modulePaths) {
			if (!walk.index.has(path)) visitScc(walk, path);
		}
		_cycles = walk.cycles;
	}
	return _cycles.get(modulePath) ?? new HashSet<string>();
}

interface SccWalk {
	graph: ModuleGraph;
	index: HashMap<string, int32>;
	low: HashMap<string, int32>;
	onStack: HashSet<string>;
	stack: string[];
	counter: int32;
	cycles: HashMap<string, HashSet<string>>;
}

function visitScc(w: SccWalk, path: string): void {
	const own = w.counter;
	w.index.set(path, own);
	w.counter += 1;
	w.stack.push(path);
	w.onStack.add(path);
	let low = own;
	const at = w.graph.modulePaths.indexOf(path);
	for (const entry of w.graph.modules[at].imports) {
		const next = entry.sourcePath;
		if (w.graph.modulePaths.indexOf(next) < 0) continue;
		if (!w.index.has(next)) {
			visitScc(w, next);
			const nextLow = w.low.get(next)!;
			if (nextLow < low) low = nextLow;
		} else if (w.onStack.has(next)) {
			const nextIndex = w.index.get(next)!;
			if (nextIndex < low) low = nextIndex;
		}
	}
	w.low.set(path, low);
	if (low != own) return;
	const members: string[] = [];
	while (true) {
		const top = w.stack.pop()!;
		w.onStack.delete(top);
		members.push(top);
		if (top == path) break;
	}
	if (members.length < 2) return;
	const set = new HashSet<string>();
	for (const m of members) set.add(m);
	for (const m of members) w.cycles.set(m, set);
}
