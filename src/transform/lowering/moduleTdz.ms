import {
	Node, NodeKind, NodeFlag, DeclKind, Symbol, SymbolKind, SymbolFlag, ProgramData, ExportDeclData, DecoratedDeclData,
	VariableDeclData, ClassDeclData, PropertyDeclData, CallExprData, MemberExprData, NewExprData,
	ExprStmtData, BinaryExprData, UpdateExprData, HiddenDerefData, OutExprData, FunctionDeclData,
} from "../../ast/node";
import { isRoutineNode } from "../../ast/shape";
import { forEachChild, anyChild } from "../../ast/visitor";
import { isEagerAssignOp } from "../../ast/operators";
import { booleanType } from "../../checker/types";
import { setFlag } from "../../checker/symbol";
import { ModuleGraph, findModuleIndex } from "../../module/graph";
import { findExportedSymbol, findModuleExports, isExtensionRoutine, isLifecycleHookName } from "../../checker/context";
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
		if (ctx.checkerCtx.liftedLocalTypeDecls.indexOf(stmts[i]) >= 0) continue;
		const decl = unwrapDecl(stmts[i]);
		const sym = lexicalBindingOf(decl);
		if (sym != null) bindings.push({ sym, statement: i });
		if (firstRun < 0 && runsModuleCode(decl, modulePath)) firstRun = i;
	}
	const deferred = new HashSet<Symbol>();
	const deferredOrder: Symbol[] = [];
	for (const stmt of stmts) collectDeferredUses(stmt, false, deferred, deferredOrder);
	const cycle = cycleOf(ctx.checkerCtx.moduleGraph, modulePath);
	const imported = cycleImportedBindings(ctx, cycle);
	const sets: Node[][] = [];
	for (let i = 0; i < stmts.length; i += 1) sets.push([]);
	const flagDecls: Node[] = [];
	const entry = cycle.size == 0 && firstRun >= 0 ? createEntryWalk(stmts, modulePath, ctx) : null;
	for (const b of bindings) {
		if (entry != null) runStatementsThrough(entry, b.statement);
		const reached = deferred.has(b.sym) && (cycle.size > 0 || (entry != null && entry.reads.has(b.sym)));
		if (!reached && !imported.has(tdzBindingOf(b.sym))) continue;
		const flag = moduleFlagOf(b.sym, modulePath, ctx);
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
		if (!isLexicalBindingSym(sym) || !imported.has(tdzBindingOf(sym))) continue;
		moduleFlagOf(sym, sym.modulePath, ctx);
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

// Without an import cycle, module code reaches a routine of this module only through a reference to it, so a
// deferred read can run before its binding is set only when a routine holding it was entered by a statement up
// to the binding's own. A routine the compiler may call with no reference written (an extension or lifecycle
// routine, a decorated declaration) counts as entered from the start, and a call to a local member enters every
// class, because dispatch may pick any of their methods.
class EntryWalk {
	stmts: Node[];
	modulePath: string;
	ctx: TransformContext;
	units: HashMap<Symbol, Node> = new HashMap<Symbol, Node>();
	classes: Symbol[] = [];
	entered: HashSet<Symbol> = new HashSet<Symbol>();
	reads: HashSet<Symbol> = new HashSet<Symbol>();
	next: int32 = 0;
	constructor(stmts: Node[], modulePath: string, ctx: TransformContext) { this.stmts = stmts; this.modulePath = modulePath; this.ctx = ctx; }
}

function createEntryWalk(stmts: Node[], modulePath: string, ctx: TransformContext): EntryWalk {
	const w = new EntryWalk(stmts, modulePath, ctx);
	for (const stmt of stmts) {
		const decl = unwrapDecl(stmt);
		if (decl == null || decl.resolvedSym == null) continue;
		if (decl.kind == NodeKind.FunctionDecl || decl.kind == NodeKind.ClassDecl) w.units.set(decl.resolvedSym, decl);
		if (decl.kind == NodeKind.ClassDecl) w.classes.push(decl.resolvedSym);
	}
	for (const stmt of stmts) {
		const decl = unwrapDecl(stmt);
		if (decl == null || decl.kind != NodeKind.FunctionDecl || decl.resolvedSym == null) continue;
		const d = decl.data as FunctionDeclData;
		if (isExtensionRoutine(d.fnFlags) || isLifecycleHookName(d.fnName) || stmt.kind == NodeKind.DecoratedDecl
			|| (stmt.kind == NodeKind.ExportDecl && (stmt.data as ExportDeclData).exportedDecl.kind == NodeKind.DecoratedDecl)) enterUnit(w, decl.resolvedSym);
	}
	return w;
}

function runStatementsThrough(w: EntryWalk, last: int32): void {
	while (w.next <= last && w.next < w.stmts.length) {
		const stmt = w.stmts[w.next];
		w.next += 1;
		if (w.ctx.checkerCtx.liftedLocalTypeDecls.indexOf(stmt) >= 0) continue;
		const decl = unwrapDecl(stmt);
		if (decl == null || decl.kind == NodeKind.FunctionDecl) continue;
		if (decl.kind == NodeKind.ClassDecl && stmt == decl) {
			for (const member of (decl.data as ClassDeclData).classBody) {
				if (member.kind == NodeKind.PropertyDecl && (member.data as PropertyDeclData).propIsStatic) scanEntered(w, (member.data as PropertyDeclData).propInitializer);
			}
			continue;
		}
		scanEntered(w, stmt);
	}
}

function enterUnit(w: EntryWalk, sym: Symbol): void {
	const unit = w.units.get(sym);
	if (unit == null || w.entered.has(sym)) return;
	w.entered.add(sym);
	scanEntered(w, unit);
}

function enterEveryClass(w: EntryWalk): void {
	for (const cls of w.classes) enterUnit(w, cls);
}

function scanEntered(w: EntryWalk, n: Node | null): void {
	if (n == null) return;
	const read = moduleBindingRead(n);
	if (read != null) {
		w.reads.add(tdzBindingOf(read));
		if (isLocal(read, w.modulePath)) enterUnit(w, tdzBindingOf(read));
	}
	if (n.kind == NodeKind.NewExpr) {
		const callee = (n.data as NewExprData).newCallee.resolvedSym;
		if (isLocal(callee, w.modulePath)) enterUnit(w, tdzBindingOf(callee!));
	}
	if (n.kind == NodeKind.CallExpr) {
		for (const sym of [n.resolvedSym, (n.data as CallExprData).callee.resolvedSym]) {
			if (!isLocal(sym, w.modulePath)) continue;
			if (w.units.has(tdzBindingOf(sym!))) enterUnit(w, tdzBindingOf(sym!));
			else if (sym!.symbolKind != SymbolKind.Variable && sym!.symbolKind != SymbolKind.Parameter) enterEveryClass(w);
		}
	}
	forEachChild(n, (c: Node): void => scanEntered(w, c));
}

// A plain read is left to the conditional-expression pass, which guards it with a statement before the
// statement that reads it, as on C, so the read stays a place. A class operand and a write are guarded here.
export function guardModuleTdzRaiser(program: Node, ctx: TransformContext): Node {
	if (ctx.tdzFlags.size == 0) return program;
	mapChildren(program, (c: Node): Node => guardUses(c, false, ctx));
	return program;
}

function guardUses(n: Node, inFunction: boolean, ctx: TransformContext): Node {
	if (n == null) return n;
	const deferred = inFunction || isRoutineNode(n)
		|| (n.kind == NodeKind.PropertyDecl && !(n.data as PropertyDeclData).propIsStatic);
	if (deferred) {
		const cls = classOperand(n, ctx);
		if (cls != null) {
			mapChildren(n, (c: Node): Node => c == cls ? c : guardUses(c, true, ctx));
			return guarded(n, cls, ctx);
		}
		const read = moduleBindingRead(n);
		if (read != null) return n;
		if (n.kind == NodeKind.ExprStmt) {
			const assign = (n.data as ExprStmtData).expr;
			if (assign.kind == NodeKind.BinaryExpr && flagOf(placeRoot((assign.data as BinaryExprData).left), ctx) != null) {
				const bd = assign.data as BinaryExprData;
				if (bd.operator == "=" && placeRoot(bd.left) == bd.left) return guardedWriteStmt(n, assign, ctx);
				if (isEagerAssignOp(bd.operator)) return guardedCompoundStmt(n, assign, ctx);
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
	if (n.kind == NodeKind.BinaryExpr && isEagerAssignOp((n.data as BinaryExprData).operator)) target = (n.data as BinaryExprData).left;
	else if (n.kind == NodeKind.UpdateExpr) target = (n.data as UpdateExprData).updateArg;
	else if (n.kind == NodeKind.HiddenAddr) target = (n.data as HiddenDerefData).expr;
	else if (n.kind == NodeKind.OutExpr) target = (n.data as OutExprData).outArg;
	if (target == null) return null;
	const root = placeRoot(target);
	return root.kind == NodeKind.Identifier ? root : null;
}

function placeRoot(place: Node): Node {
	let n = place;
	while (n.kind == NodeKind.MemberExpr && moduleBindingRead(n) == null) n = (n.data as MemberExprData).object;
	return n;
}

function flagOf(n: Node, ctx: TransformContext): Symbol | null {
	const read = moduleBindingRead(n);
	return read == null ? null : ctx.tdzFlags.get(tdzBindingOf(read));
}

// The binding a node reads by name: an identifier, or a member of a namespace import
// (`ns.x` keeps its MemberExpr and carries the exported symbol).
export function moduleBindingRead(n: Node): Symbol | null {
	if (n.resolvedSym == null) return null;
	if (n.kind == NodeKind.Identifier) return n.resolvedSym;
	if (n.kind != NodeKind.MemberExpr) return null;
	const object = (n.data as MemberExprData).object;
	return object.resolvedSym != null && object.resolvedSym.symbolKind == SymbolKind.Module ? n.resolvedSym : null;
}

function failCall(binding: Node, ctx: TransformContext): Node | null {
	const fail = compilerFuncSym("msModuleBindingUninitialized");
	if (fail == null) {
		reportTransformError(ctx, "internal: std declares no msModuleBindingUninitialized to guard a module binding read before its declaration", binding.location);
		return null;
	}
	return makeCallResolved(makeIdentResolved(fail, binding.location), [makeString(tdzBindingOf(moduleBindingRead(binding)!).name, binding.location)], fail, binding.location);
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

// A compound write reads its binding first, so it throws before its right side runs; the statement stays
// a statement because a string append lowers to a call that cannot sit inside a conditional expression.
function guardedCompoundStmt(stmt: Node, assign: Node, ctx: TransformContext): Node {
	const bd = assign.data as BinaryExprData;
	bd.right = guardUses(bd.right, true, ctx);
	const root = placeRoot(bd.left);
	const fail = failCall(root, ctx);
	if (fail == null) return stmt;
	const loc = stmt.location;
	return makeIf(makeIdentResolved(flagOf(root, ctx)!, loc), makeBlock([stmt], loc), makeBlock([makeExprStmt(fail, loc)], loc), loc);
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

const _moduleFlags = new HashMap<Symbol, Symbol>();

function moduleFlagOf(binding: Symbol, modulePath: string, ctx: TransformContext): Symbol {
	let flag = _moduleFlags.get(binding);
	if (flag == null) {
		flag = mintSym(ctx, SymbolKind.Variable, binding.name + "$init", booleanType());
		flag.disamb = binding.disamb;
		markModuleFlag(flag, modulePath);
		_moduleFlags.set(binding, flag);
	}
	ctx.tdzFlags.set(binding, flag);
	return flag;
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

function collectDeferredUses(n: Node, inFunction: boolean, uses: HashSet<Symbol>, order: Symbol[]): void {
	if (n == null) return;
	const read = inFunction ? moduleBindingRead(n) : null;
	if (read != null && !uses.has(tdzBindingOf(read))) {
		uses.add(tdzBindingOf(read));
		order.push(tdzBindingOf(read));
	}
	const deferred = inFunction || isRoutineNode(n)
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
	return anyChild(n, (c: Node): boolean => reachesLocalCode(c, modulePath));
}

// The bindings the importers in a cycle can reach: each import entry resolved through the
// export registry, so a renaming barrel and a namespace import name the declaring symbol.
function cycleImportedBindings(ctx: TransformContext, cycle: HashSet<string>): HashSet<Symbol> {
	const out = new HashSet<Symbol>();
	const graph = ctx.checkerCtx.moduleGraph;
	if (graph == null || cycle.size == 0) return out;
	const registry = ctx.checkerCtx.exportRegistry;
	for (const path of graph.modulePaths) {
		if (!cycle.has(path)) continue;
		for (const entry of graph.modules[findModuleIndex(graph, path)].imports) {
			if (entry.names.length == 1 && entry.names[0] == "*") {
				const exports = findModuleExports(registry, entry.sourcePath);
				if (exports != null) for (const info of exports.symbols) out.add(tdzBindingOf(info.sym));
				continue;
			}
			for (const name of entry.names) {
				const info = findExportedSymbol(registry, entry.sourcePath, name);
				if (info != null && info.sym != null) out.add(tdzBindingOf(info.sym));
			}
		}
	}
	return out;
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
	const at = findModuleIndex(w.graph, path);
	for (const entry of w.graph.modules[at].imports) {
		const next = entry.sourcePath;
		if (findModuleIndex(w.graph, next) < 0) continue;
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
