import { Node, NodeKind, NodeFlag, Symbol, SymbolKind, Type, TypeKind, BinaryExprData, CallExprData, NewExprData, MemberExprData, MoveExprData, ObjectLiteralData, ArrayLiteralData, IfStmtData, ConditionalExprData, ConstructorDeclData, FunctionDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { ModuleGraph, findModule } from "../module/graph";
import { CheckerContext } from "./context";
import { SymbolFlag, hasFlag } from "./symbol";
import { calledRoutineType } from "./effects";
import { boundElement, getElementType, isSinkTypeForParam, isUncountedElement, isUnownedSlot, unwrapRefNullUnion } from "./types";

// Bit 0 of `sunkParams`, the receiver's position: the bits are final.
const SETTLED: int32 = 1;

// Parameter `param` is handed, on every path, to parameter `calleeParam` of constructor `callee`.
class Forward {
	param: int32;
	callee: Symbol;
	calleeParam: int32;
}

class SunkScan {
	params: Symbol[];
	bits: int32;
	returned: boolean;
	forwards: Forward[];
	home: string;
	graph: ModuleGraph | null;
}

class Unsettled {
	routine: Symbol;
	forwards: Forward[];
}

let _unsettled: Unsettled[] = [];

function heldRoutine(routine: Symbol): Symbol {
	const held = routine.ctorOwner != null ? routine.ctorOwner.ctorRoutine : null;
	return held != null ? held : routine;
}

function ctorRoot(routine: Symbol): Symbol {
	let root = heldRoutine(routine);
	while (root.instantiatedFrom != null) root = heldRoutine(root.instantiatedFrom);
	return root;
}

function bodyOf(routine: Symbol): Node | null {
	const decl = routine.declNode;
	if (decl == null) return null;
	if (decl.kind == NodeKind.ConstructorDecl) return (decl.data as ConstructorDeclData).ctorBody;
	return decl.kind == NodeKind.FunctionDecl ? (decl.data as FunctionDeclData).fnBody : null;
}

// A constructor takes the parameters its body keeps. One with no body to read (an extern class)
// takes every parameter, and one whose body was never checked takes none.
export function ctorKeepsParam(routine: Symbol, param: int32): boolean {
	const root = ctorRoot(routine);
	if ((root.sunkParams & SETTLED) == 0) return bodyOf(root) == null;
	return param > 0 && param < 31 && (root.sunkParams & (1 << param)) != 0;
}

// False only for a constructor whose body exists and was never read: no caller may guess for it.
export function ctorParamsKnown(routine: Symbol): boolean {
	const root = ctorRoot(routine);
	return (root.sunkParams & SETTLED) != 0 || bodyOf(root) == null;
}

function importsModule(graph: ModuleGraph | null, from: string, to: string): boolean {
	if (graph == null || from == "" || to == "") return false;
	const seen = new HashSet<string>();
	const todo: string[] = [from];
	while (todo.length > 0) {
		const path = todo.pop()!;
		if (seen.has(path)) continue;
		seen.add(path);
		const mod = findModule(graph, path);
		if (mod == null) continue;
		for (const entry of mod.imports) {
			if (entry.sourcePath == to) return true;
			if (entry.sourcePath != "") todo.push(entry.sourcePath);
		}
	}
	return false;
}

function paramAt(arg: Node | null, st: SunkScan): int32 {
	if (arg == null || arg.kind != NodeKind.Identifier || arg.resolvedSym == null) return -1;
	return st.params.indexOf(arg.resolvedSym) as int32;
}

function take(at: int32, st: SunkScan): void {
	if (at > 0 && at < 31) st.bits = st.bits | (1 << at);
}

function ownsWhatItHolds(slot: Type | null): boolean {
	return slot != null && !isUnownedSlot(slot) && !isUncountedElement(slot) && slot.kind != TypeKind.Span;
}

function isLocalOfFrame(target: Node): boolean {
	const sym = target.resolvedSym;
	if (target.kind != NodeKind.Identifier || sym == null) return false;
	if (sym.symbolKind == SymbolKind.Parameter) return true;
	return (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Temp)
		&& !hasFlag(sym, SymbolFlag.Global) && !hasFlag(sym, SymbolFlag.StaticLocal);
}

function fieldSlot(objType: Type | null, name: string): Type | null {
	if (objType == null) return null;
	const bare = objType.kind == TypeKind.Union ? unwrapRefNullUnion(objType) : objType;
	const t = bare != null && bare.kind == TypeKind.Ref && bare.typeReturn != null ? bare.typeReturn : bare;
	if (t == null || t.typeChildren == null || t.typeNames == null) return null;
	const at = t.typeNames.indexOf(name);
	return at >= 0 && at < t.typeChildren.length ? t.typeChildren[at] : null;
}

function constructorCalled(routine: Symbol | null): Symbol | null {
	return routine != null && routine.ctorOwner != null ? routine : null;
}

// An argument of `new K(...)` or `super(...)` is kept when K keeps that parameter. K's answer may
// not be known yet, so the hand-over is recorded and settled later. A constructor in a module
// that imports this one back is checked in an order the import graph does not fix, so its
// answer is never read: the parameter stays lent.
function forwardArgs(args: Node[], called: Symbol, st: SunkScan): void {
	const callee = ctorRoot(called);
	const formals = called.symbolType != null && called.symbolType.kind == TypeKind.Function ? called.symbolType.typeChildren : null;
	for (let i = 0; i < args.length; i += 1) {
		const at = paramAt(args[i], st);
		const formal = formals != null && i + 1 < formals.length ? formals[i + 1] : null;
		if (at <= 0 || (formal != null && formal.kind == TypeKind.Varargs)) continue;
		if (bodyOf(callee) == null || isSinkTypeForParam(formal)) take(at, st);
		else if (callee.modulePath == st.home || !importsModule(st.graph, callee.modulePath, st.home)) st.forwards.push({ param: at, callee, calleeParam: i + 1 });
	}
}

function sinkSites(n: Node, st: SunkScan): void {
	if (n.kind == NodeKind.BinaryExpr) {
		const d = n.data as BinaryExprData;
		if (d.operator == "=" && !isLocalOfFrame(d.left) && ownsWhatItHolds(d.left.nodeType)) take(paramAt(d.right, st), st);
	} else if (n.kind == NodeKind.CallExpr) {
		const d = n.data as CallExprData;
		const ctor = constructorCalled(n.resolvedSym != null ? n.resolvedSym : d.callee.resolvedSym);
		if (ctor != null) {
			forwardArgs(d.arguments, ctor, st);
			return;
		}
		const all = calledRoutineType(n)?.typeChildren ?? null;
		if (all == null) return;
		const withReceiver = all.length > 0 && n.flags.has(NodeFlag.ExtCall) && !n.flags.has(NodeFlag.ExtStatic) && d.callee.kind == NodeKind.MemberExpr;
		const formals = withReceiver ? all.slice(1) : all;
		for (let i = 0; i < d.arguments.length && i < formals.length; i += 1) {
			if (paramAt(d.arguments[i], st) < 0 || !isSinkTypeForParam(formals[i])) continue;
			const bound = boundElement(formals, i, d.arguments, withReceiver ? all[0] : null, d.callee);
			if (bound == null || ownsWhatItHolds(bound)) take(paramAt(d.arguments[i], st), st);
		}
	} else if (n.kind == NodeKind.ObjectLiteral) {
		const d = n.data as ObjectLiteralData;
		for (let i = 0; i < d.properties.length && i < d.keys.length; i += 1) {
			if (ownsWhatItHolds(fieldSlot(n.nodeType, d.keys[i]))) take(paramAt(d.properties[i], st), st);
		}
	} else if (n.kind == NodeKind.ArrayLiteral && n.nodeType != null && ownsWhatItHolds(getElementType(n.nodeType))) {
		for (const e of (n.data as ArrayLiteralData).elements) take(paramAt(e, st), st);
	} else if (n.kind == NodeKind.NewExpr) {
		const ctor = constructorCalled(n.resolvedSym);
		if (ctor != null) forwardArgs((n.data as NewExprData).newArguments, ctor, st);
	}
}

const CONDITIONAL_KINDS = [
	NodeKind.SwitchStmt, NodeKind.MatchExpr, NodeKind.MatchStmt, NodeKind.WhileStmt, NodeKind.DoWhileStmt,
	NodeKind.ForStmt, NodeKind.ForOfStmt, NodeKind.ForInStmt, NodeKind.TryCatchStmt, NodeKind.TryExpr, NodeKind.DeferStmt,
];
const SHORT_CIRCUITS = ["&&", "||", "??", "&&=", "||=", "??="];

function scan(n: Node | null, st: SunkScan, conditional: boolean): void {
	if (n == null) return;
	if (n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ClassDecl) return;
	if (n.kind == NodeKind.MoveExpr) {
		take(paramAt((n.data as MoveExprData).moveArg, st), st);
		return;
	}
	if (!conditional && !st.returned) sinkSites(n, st);
	if (n.kind == NodeKind.IfStmt) {
		const d = n.data as IfStmtData;
		scan(d.condition, st, conditional);
		scan(d.consequent, st, true);
		scan(d.alternate, st, true);
		return;
	}
	if (n.kind == NodeKind.ConditionalExpr) {
		const d = n.data as ConditionalExprData;
		scan(d.ternaryCondition, st, conditional);
		scan(d.ternaryConsequent, st, true);
		scan(d.ternaryAlternate, st, true);
		return;
	}
	if (n.kind == NodeKind.BinaryExpr && SHORT_CIRCUITS.includes((n.data as BinaryExprData).operator)) {
		scan((n.data as BinaryExprData).left, st, conditional);
		scan((n.data as BinaryExprData).right, st, true);
		return;
	}
	const optional = n.flags.has(NodeFlag.OptionalLink) || (n.kind == NodeKind.MemberExpr && (n.data as MemberExprData).isOptional);
	const inside = conditional || optional || CONDITIONAL_KINDS.includes(n.kind);
	forEachChild(n, (c: Node): void => scan(c, st, inside));
	if (n.kind == NodeKind.ReturnStmt) st.returned = true;
}

function everyParam(params: Symbol[] | null): int32 {
	let bits: int32 = 0;
	for (let i = 1; params != null && i < params.length && i < 31; i += 1) bits = bits | (1 << i);
	return bits;
}

// Settles every waiting constructor whose hand-overs all reach settled constructors or other
// waiting ones: together they take the least set of parameters their bodies justify. With
// `all`, a hand-over to a constructor that never settled is dropped, so nothing waits past the
// check of its own module.
function settle(all: boolean): void {
	let ready = _unsettled;
	let dropped = !all;
	while (dropped) {
		dropped = false;
		const still: Unsettled[] = [];
		for (const u of ready) {
			const known = u.forwards.every((f: Forward): boolean => (f.callee.sunkParams & SETTLED) != 0 || ready.some((o: Unsettled): boolean => o.routine == f.callee));
			if (known) still.push(u);
			else dropped = true;
		}
		ready = still;
	}
	let grew = true;
	while (grew) {
		grew = false;
		for (const u of ready) {
			for (const f of u.forwards) {
				const taken = f.calleeParam < 31 && (f.callee.sunkParams & (1 << f.calleeParam)) != 0;
				if (taken && (u.routine.sunkParams & (1 << f.param)) == 0) {
					u.routine.sunkParams = u.routine.sunkParams | (1 << f.param);
					grew = true;
				}
			}
		}
	}
	for (const u of ready) u.routine.sunkParams = u.routine.sunkParams | SETTLED;
	_unsettled = _unsettled.filter((u: Unsettled): boolean => !ready.includes(u));
}

// Called when the check of a module ends.
export function settleCtorSunkParams(): void {
	if (_unsettled.length > 0) settle(true);
}

// Called where the body of a constructor has just been checked. Bit i of `sunkParams` is set when
// the body moves parameter i into an owning place on every path that completes normally before a
// `return`: a store into a slot that holds a count, an argument of a `sink` formal, an element of
// an object or array literal, a parameter property, a written `move`, or an argument of a
// constructor that keeps it. A parameter kept only through an Unowned or uncounted slot or
// stored under a condition stays lent. An actor's constructor takes every parameter, because
// its arguments cross to the actor. `params[0]` is the receiver and is never taken.
export function noteCtorSunkParams(ctx: CheckerContext, routine: Symbol, ctor: Node, owner: Symbol | null): void {
	const d = ctor.data as ConstructorDeclData;
	const params = ctor.paramSyms;
	if (routine.instantiatedFrom != null) return;
	if (d.ctorBody == null || params == null || (owner != null && owner.symbolKind == SymbolKind.Actor)) {
		routine.sunkParams = everyParam(params) | SETTLED;
	} else {
		const st: SunkScan = { params, bits: 0, returned: false, forwards: [], home: routine.modulePath, graph: ctx.moduleGraph };
		for (let i = 0; i < d.ctorParamProps.length && i + 1 < params.length; i += 1) {
			if (d.ctorParamProps[i] != null && ownsWhatItHolds(params[i + 1].symbolType)) take(i + 1, st);
		}
		scan(d.ctorBody, st, false);
		routine.sunkParams = st.bits;
		if (st.forwards.length == 0) routine.sunkParams = routine.sunkParams | SETTLED;
		else _unsettled.push({ routine, forwards: st.forwards });
	}
	if (_unsettled.length > 0) settle(false);
}
