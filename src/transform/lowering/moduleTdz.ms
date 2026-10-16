import {
	Node, NodeKind, NodeFlag, DeclKind, Symbol, SymbolKind, SymbolFlag, ProgramData, ExportDeclData, DecoratedDeclData,
	VariableDeclData, ClassDeclData, PropertyDeclData, CallExprData, MemberExprData, NewExprData,
	ExprStmtData, BinaryExprData, UpdateExprData, HiddenDerefData, OutExprData,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { booleanType } from "../../checker/types";
import { makeSymbol, setFlag } from "../../checker/symbol";
import { ModuleGraph, Module } from "../../module/graph";
import { TransformContext, mintSym, reportTransformError } from "../context";
import { mapChildren, hasEffect } from "../walker";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { makeVarDecl, makeAssign, makeExprStmt, makeIdentResolved, makeBool, makeString, makeCallResolved, makeConditional, makeIf, makeBlock, compilerFuncSym } from "../util";

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
		const flag = mintSym(ctx, SymbolKind.Variable, initFlagName(b.sym.name), booleanType());
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
		const flag = makeSymbol(initFlagName(sym.name), SymbolKind.Variable, booleanType(), true);
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

// The Raiser runs no ordered statement hoist, so a guarded use stays an expression
// there and the VM evaluates it in place.
export function guardModuleTdzRaiser(program: Node, ctx: TransformContext): Node {
	if (ctx.tdzFlags.size == 0) return program;
	mapChildren(program, (c: Node): Node => guardUses(c, false, ctx));
	return program;
}

function guardUses(n: Node, inFunction: boolean, ctx: TransformContext): Node {
	if (n == null) return n;
	const deferred = inFunction || isFunctionLike(n)
		|| (n.kind == NodeKind.PropertyDecl && !(n.data as PropertyDeclData).propIsStatic);
	if (deferred) {
		const cls = classOperand(n, ctx);
		if (cls != null) {
			mapChildren(n, (c: Node): Node => c == cls ? c : guardUses(c, true, ctx));
			return guarded(n, cls, ctx);
		}
		if (n.kind == NodeKind.Identifier) return n.resolvedSym != null && n.resolvedSym.symbolKind == SymbolKind.Class ? n : guarded(n, n, ctx);
		if (n.kind == NodeKind.ExprStmt) {
			const assign = (n.data as ExprStmtData).expr;
			if (assign.kind == NodeKind.BinaryExpr && (assign.data as BinaryExprData).operator == "=" && flagOf((assign.data as BinaryExprData).left, ctx) != null) {
				return guardedWriteStmt(n, assign, ctx);
			}
		}
		const target = writtenBinding(n);
		if (target != null && flagOf(target, ctx) != null) {
			if (n.kind == NodeKind.BinaryExpr) {
				const bd = n.data as BinaryExprData;
				bd.right = guardUses(bd.right, true, ctx);
			}
			return guarded(n, target, ctx);
		}
	}
	mapChildren(n, (c: Node): Node => guardUses(c, deferred, ctx));
	return n;
}

// A class binding names no value on the Raiser: its `new` or `instanceof` is guarded whole.
function classOperand(n: Node, ctx: TransformContext): Node | null {
	let operand: Node | null = null;
	if (n.kind == NodeKind.NewExpr) operand = (n.data as NewExprData).newCallee;
	else if (n.kind == NodeKind.BinaryExpr && (n.data as BinaryExprData).operator == "instanceof") operand = (n.data as BinaryExprData).right;
	if (operand == null || operand.resolvedSym == null || operand.resolvedSym.symbolKind != SymbolKind.Class || flagOf(operand, ctx) == null) return null;
	return operand;
}

function writtenBinding(n: Node): Node | null {
	let target: Node | null = null;
	if (n.kind == NodeKind.BinaryExpr && isAssignOperator((n.data as BinaryExprData).operator)) target = (n.data as BinaryExprData).left;
	else if (n.kind == NodeKind.UpdateExpr) target = (n.data as UpdateExprData).updateArg;
	else if (n.kind == NodeKind.HiddenAddr) target = (n.data as HiddenDerefData).expr;
	else if (n.kind == NodeKind.OutExpr) target = (n.data as OutExprData).outArg;
	return target != null && target.kind == NodeKind.Identifier ? target : null;
}

function isAssignOperator(op: string): boolean {
	return match (op) {
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" => true,
		"&=" | "|=" | "^=" | "<<=" | ">>=" | ">>>=" => true,
		_ => false,
	};
}

function flagOf(n: Node, ctx: TransformContext): Symbol | null {
	if (n.kind != NodeKind.Identifier || n.resolvedSym == null) return null;
	return ctx.tdzFlags.get(tdzBindingOf(n.resolvedSym));
}

function failCall(binding: Node, ctx: TransformContext): Node | null {
	const fail = compilerFuncSym("msModuleBindingUninitialized");
	if (fail == null) {
		reportTransformError(ctx, "internal: std declares no msModuleBindingUninitialized to guard a module binding read before its declaration", binding.location);
		return null;
	}
	return makeCallResolved(makeIdentResolved(fail, binding.location), [makeString(tdzBindingOf(binding.resolvedSym!).name, binding.location)], fail, binding.location);
}

function guarded(use: Node, binding: Node, ctx: TransformContext): Node {
	const flag = flagOf(binding, ctx);
	if (flag == null) return use;
	const fail = failCall(binding, ctx);
	if (fail == null) return use;
	const result = makeConditional(makeIdentResolved(flag, use.location), use, fail, use.location);
	result.nodeType = use.nodeType;
	return result;
}

// A write to a module binding throws after its value is evaluated (ECMAScript PutValue).
function guardedWriteStmt(stmt: Node, assign: Node, ctx: TransformContext): Node {
	const bd = assign.data as BinaryExprData;
	bd.right = guardUses(bd.right, true, ctx);
	const fail = failCall(bd.left, ctx);
	if (fail == null) return stmt;
	const loc = stmt.location;
	const otherwise: Node[] = [];
	if (hasEffect(bd.right)) otherwise.push(makeExprStmt(cloneNodeKeepSem(bd.right), loc));
	otherwise.push(makeExprStmt(fail, loc));
	return makeIf(makeIdentResolved(flagOf(bd.left, ctx)!, loc), makeBlock([stmt], loc), makeBlock(otherwise, loc), loc);
}

export function initFlagName(binding: string): string {
	return binding + "$init";
}

function markModuleFlag(flag: Symbol, modulePath: string): void {
	flag.modulePath = modulePath;
	setFlag(flag, SymbolFlag.Global);
	setFlag(flag, SymbolFlag.Mutable);
	setFlag(flag, SymbolFlag.InitFlag);
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

export function tdzBindingOf(sym: Symbol): Symbol {
	return sym.instantiatedFrom != null ? sym.instantiatedFrom : sym;
}

function lexicalBindingOf(decl: Node): Symbol | null {
	if (decl == null || decl.resolvedSym == null) return null;
	if (decl.kind == NodeKind.ClassDecl) return decl.resolvedSym.instantiatedFrom == null ? decl.resolvedSym : null;
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
	if (inFunction && n.kind == NodeKind.Identifier && n.resolvedSym != null && !uses.has(tdzBindingOf(n.resolvedSym))) {
		uses.add(tdzBindingOf(n.resolvedSym));
		order.push(tdzBindingOf(n.resolvedSym));
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
