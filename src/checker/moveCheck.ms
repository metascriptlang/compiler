import {
	Node, NodeKind, Symbol, SymbolKind, FlowNode, FlowFlag, FlowList,
	IdentifierData, BinaryExprData, MoveExprData, OutExprData, CallExprData, NewExprData,
	HiddenDerefData, HiddenStdConvData, ArrayLiteralData, ObjectLiteralData, SpreadExprData,
	VariableDeclData, ReturnStmtData, TypeAssertionData, UpdateExprData, Type, TypeKind, BlockStmtData, ProgramData,
	FunctionDeclData, MethodDeclData, ConstructorDeclData, ArrowFunctionData, FunctionExprData, MemberExprData, ArrayAccessData, TestDeclData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { isAssignOp } from "../ast/operators";
import { CheckerContext, LockedMove, addError } from "./context";
import { Overlap, Place, PlaceScope, StepKind, overlap, placeOf, placeScope } from "./places";
import { routineBody } from "./effects";
import { hasFlag, SymbolFlag } from "./symbol";
import { ownedEdgeOf, isSinkTypeForParam, typeDisplayName } from "./types";
import { calledRoutineType } from "./effects";

export interface MoveEvent {
	at: Node;
	sym: Symbol;
	owner: boolean;
}

interface Pending {
	flow: FlowNode | null;
	anchor: Node | null;
}

interface RootFault {
	at: Node;
	why: string;
}

export class MoveScan {
	moves: MoveEvent[] = [];
	faults: RootFault[] = [];
	deferScopes = new HashMap<Node, Node>();
	firstOrder = new HashMap<Node, int32>();
	moved = new HashSet<Symbol>();
	reads = new HashMap<Symbol, Node[]>();
	order = new HashMap<Node, int32>();
	next: int32 = 0;
	writes = new HashSet<Node>();
}

function stripHidden(n: Node | null): Node | null {
	let walk = n;
	while (walk != null) {
		if (walk.kind == NodeKind.HiddenDeref || walk.kind == NodeKind.HiddenAddr) {
			walk = (walk.data as HiddenDerefData).expr;
		} else if (walk.kind == NodeKind.HiddenStdConv || walk.kind == NodeKind.HiddenSubConv) {
			walk = (walk.data as HiddenStdConvData).convExpr;
		} else {
			return walk;
		}
	}
	return walk;
}

function movableSym(sym: Symbol | null): boolean {
	return sym != null && (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter);
}

function movedIdent(move: Node): Node | null {
	const arg = stripHidden((move.data as MoveExprData).moveArg);
	return arg != null && arg.kind == NodeKind.Identifier && movableSym(arg.resolvedSym) ? arg : null;
}

function take(scan: MoveScan, at: Node, owner: boolean): void {
	if (at.flowNode == null) return;
	scan.moves.push({ at, sym: at.resolvedSym!, owner });
	scan.moved.add(at.resolvedSym!);
}

// A local that holds an owned edge, read where the value is consumed: the read is its last use, or a copy.
function ownedLocalAt(expr: Node | null): Node | null {
	let e = expr;
	while (e != null && ownedEdgeOf(e.nodeType) != null) {
		if (e.kind == NodeKind.Identifier) {
			const sym = e.resolvedSym;
			const decl = sym != null ? sym.declNode : null;
			return sym != null && sym.symbolKind == SymbolKind.Variable && !hasFlag(sym, SymbolFlag.Global)
				&& decl != null && decl.kind == NodeKind.VariableDecl ? e : null;
		}
		if (e.kind == NodeKind.HiddenStdConv || e.kind == NodeKind.HiddenSubConv) {
			e = (e.data as HiddenStdConvData).convExpr;
		} else if (e.kind == NodeKind.TypeAssertion) {
			e = (e.data as TypeAssertionData).asExpr;
		} else {
			return null;
		}
	}
	return null;
}

function consumed(scan: MoveScan, expr: Node | null): void {
	const local = ownedLocalAt(expr);
	if (local != null) take(scan, local, true);
}

function consumedArgs(scan: MoveScan, call: Node): void {
	const args = (call.data as CallExprData).arguments;
	const fnType = calledRoutineType(call);
	if (fnType == null) return;
	const formals: Type[] = fnType.typeChildren;
	const offset = formals.length == args.length + 1 ? 1 : 0;
	for (let i = 0; i < args.length; i += 1) {
		const at = i + offset;
		if (at < formals.length && isSinkTypeForParam(formals[at])) consumed(scan, args[i]);
	}
}

function routineParams(node: Node): string[] | null {
	return match (node.kind) {
		NodeKind.FunctionDecl => (node.data as FunctionDeclData).params,
		NodeKind.MethodDecl => (node.data as MethodDeclData).methodParams,
		NodeKind.ConstructorDecl => (node.data as ConstructorDeclData).ctorParams,
		NodeKind.ArrowFunction => (node.data as ArrowFunctionData).arrowParams,
		NodeKind.FunctionExpr => (node.data as FunctionExprData).funcExprParams,
		_ => null,
	};
}

function routineOwning(sym: Symbol, routines: Node[]): Node | null {
	for (let i = routines.length - 1; i >= 0; i -= 1) {
		if (routineParams(routines[i])!.includes(sym.name)) return routines[i];
	}
	return null;
}

// Why the frame does not own what `sym` names, so `move sym` cannot take it, or "".
function rootFault(sym: Symbol, routines: Node[]): string {
	if (hasFlag(sym, SymbolFlag.Global) && routines.length > 0) return "it is a module-level binding that every function in the module can reach — move a binding local to one function";
	const decl = sym.declNode;
	if (hasFlag(sym, SymbolFlag.ForVar) && (decl == null || decl.kind != NodeKind.ForInStmt)) {
		return "it is a for..of element the collection lends for one iteration — copy it instead";
	}
	if (sym.symbolKind != SymbolKind.Parameter) return "";
	if (hasFlag(sym, SymbolFlag.Sink) || isSinkTypeForParam(sym.symbolType) || (sym.symbolType != null && sym.symbolType.kind == TypeKind.Var)) return "";
	const owner = routineOwning(sym, routines);
	if (owner == null || owner.kind == NodeKind.ConstructorDecl) return "";
	return "it is a parameter, so the caller still owns it — declare it 'sink', or bind a fresh value locally and move that";
}

function collectMoves(node: Node | null, scan: MoveScan, routines: Node[]): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.MoveExpr => {
			const arg = movedIdent(node);
			const why = arg != null ? rootFault(arg.resolvedSym!, routines) : "";
			if (why != "") {
				scan.faults.push({ at: arg!, why });
			} else if (arg != null) {
				take(scan, arg, false);
			}
		},
		NodeKind.VariableDecl => consumed(scan, (node.data as VariableDeclData).initializer),
		NodeKind.ReturnStmt => consumed(scan, (node.data as ReturnStmtData).argument),
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator == "=") consumed(scan, d.right);
		},
		NodeKind.ArrayLiteral => { for (const el of (node.data as ArrayLiteralData).elements) consumed(scan, el); },
		NodeKind.ObjectLiteral => { for (const prop of (node.data as ObjectLiteralData).properties) consumed(scan, prop); },
		NodeKind.NewExpr => { for (const arg of (node.data as NewExprData).newArguments) consumed(scan, arg); },
		NodeKind.CallExpr => consumedArgs(scan, node),
		_ => {},
	};
	const routine = routineParams(node) != null;
	if (routine) routines.push(node);
	forEachChild(node, (child: Node): void => { collectMoves(child, scan, routines); });
	if (routine) routines.pop();
}

function markPatternWrites(target: Node | null, scan: MoveScan): void {
	const t = stripHidden(target);
	if (t == null) return;
	if (t.kind == NodeKind.Identifier) {
		scan.writes.add(t);
	} else if (t.kind == NodeKind.ArrayLiteral) {
		for (const el of (t.data as ArrayLiteralData).elements) { markPatternWrites(el, scan); }
	} else if (t.kind == NodeKind.ObjectLiteral) {
		for (const prop of (t.data as ObjectLiteralData).properties) { markPatternWrites(prop, scan); }
	} else if (t.kind == NodeKind.SpreadExpr) {
		markPatternWrites((t.data as SpreadExprData).spreadArg, scan);
	}
}

function stamp(node: Node, scan: MoveScan): void {
	scan.order.set(node, scan.next);
	scan.next += 1;
}

export function numberNodes(node: Node | null, scan: MoveScan): void {
	if (node == null) return;
	if (node.kind == NodeKind.BinaryExpr && isAssignOp((node.data as BinaryExprData).operator)) {
		const d = node.data as BinaryExprData;
		if (d.operator == "=") markPatternWrites(d.left, scan);
		numberNodes(d.right, scan);
		numberNodes(d.left, scan);
		stamp(node, scan);
		return;
	}
	if (node.kind == NodeKind.OutExpr) {
		const target = stripHidden((node.data as OutExprData).outArg);
		if (target != null && target.kind == NodeKind.Identifier) scan.writes.add(target);
	}
	const stmts = node.kind == NodeKind.BlockStmt ? (node.data as BlockStmtData).statements
		: node.kind == NodeKind.Program ? (node.data as ProgramData).programStmts : [];
	for (const st of stmts) {
		if (st.kind == NodeKind.DeferStmt) scan.deferScopes.set(st, node);
	}
	if (node.kind == NodeKind.DeferStmt) scan.firstOrder.set(node, scan.next);
	forEachChild(node, (child: Node): void => { numberNodes(child, scan); });
	stamp(node, scan);
	if (node.kind == NodeKind.Identifier && node.resolvedSym != null && scan.moved.has(node.resolvedSym) && !scan.writes.has(node)) {
		const known = scan.reads.get(node.resolvedSym);
		if (known != null) {
			known.push(node);
		} else {
			scan.reads.set(node.resolvedSym, [node]);
		}
	}
}

function declaresSym(node: Node | null, sym: Symbol): boolean {
	if (node == null) return false;
	if (sym.declNode == node || node.resolvedSym == sym) {
		return node.kind == NodeKind.VariableDecl || node.kind == NodeKind.DestructuringDecl
			|| node.kind == NodeKind.ForOfStmt || node.kind == NodeKind.ForInStmt || node.kind == NodeKind.TryCatchStmt;
	}
	if (node.kind != NodeKind.BinaryExpr || (node.data as BinaryExprData).operator != "=") return false;
	return patternBinds((node.data as BinaryExprData).left, sym);
}

function patternBinds(target: Node | null, sym: Symbol): boolean {
	const t = stripHidden(target);
	if (t == null) return false;
	if (t.kind == NodeKind.Identifier) return t.resolvedSym == sym;
	if (t.kind == NodeKind.ArrayLiteral) return (t.data as ArrayLiteralData).elements.some((el: Node): boolean => patternBinds(el, sym));
	if (t.kind == NodeKind.ObjectLiteral) return (t.data as ObjectLiteralData).properties.some((p: Node): boolean => patternBinds(p, sym));
	if (t.kind == NodeKind.SpreadExpr) return patternBinds((t.data as SpreadExprData).spreadArg, sym);
	return false;
}

function writesOut(call: Node | null, sym: Symbol): boolean {
	if (call == null) return false;
	const args = call.kind == NodeKind.CallExpr ? (call.data as CallExprData).arguments
		: call.kind == NodeKind.NewExpr ? (call.data as NewExprData).newArguments : [];
	for (const a of args) {
		const passed = stripHidden(a);
		if (passed == null || passed.kind != NodeKind.OutExpr) continue;
		const target = stripHidden((passed.data as OutExprData).outArg);
		if (target != null && target.kind == NodeKind.Identifier && target.resolvedSym == sym) return true;
	}
	return false;
}

function orderOf(scan: MoveScan, n: Node): int32 {
	const at = scan.order.get(n);
	return at != null ? at : -1;
}

function takenAfter(scan: MoveScan, events: MoveEvent[] | null, anchor: Node | null): MoveEvent | null {
	if (events == null) return null;
	for (const e of events) {
		if (anchor == null || orderOf(scan, anchor) > orderOf(scan, e.at)) return e;
	}
	return null;
}

// The move event in `events` that can have run before `read` with no flow node between them that `refills`, or
// null: a backward walk over the flow graph from the read, as narrowing walks it. A read inside a
// closure is not followed out of it, because moving a captured variable is refused on its own (NIM-REF AN-8). Two nodes on one flow
// node share a straight-line stretch, so evaluation order decides between them. A defer body runs when its
// block exits, so every move in that block outside the body reaches it, even one refilled later. `clean` holds the flow
// nodes an earlier walk over the same events and refills left without finding an event.
export function reachingMove(scan: MoveScan, read: Node, events: HashMap<FlowNode, MoveEvent[]>, clean: HashSet<FlowNode>, refills: (flow: FlowNode) => boolean): MoveEvent | null {
	const todo: Pending[] = [{ flow: read.flowNode, anchor: read }];
	const seen = new HashSet<FlowNode>();
	const visited: FlowNode[] = [];
	while (todo.length > 0) {
		const p = todo.pop();
		const flow = p.flow;
		if (flow == null) continue;
		const found = takenAfter(scan, events.get(flow), p.anchor);
		if (found != null) return found;
		if (seen.has(flow) || clean.has(flow)) continue;
		seen.add(flow);
		visited.push(flow);
		const flags = flow.flags;
		if (flags.has(FlowFlag.Unreachable)) continue;
		if (flags.has(FlowFlag.Start)) {
			const deferred = flow.node;
			if (deferred == null || deferred.kind != NodeKind.DeferStmt) continue;
			const scope = scan.deferScopes.get(deferred);
			const runsAt = scope != null ? orderOf(scan, scope) : scan.next;
			const bodyFrom = scan.firstOrder.get(deferred) ?? runsAt;
			for (const list of events.values()) {
				for (const e of list) {
					const at = orderOf(scan, e.at);
					if (at < runsAt && (at < bodyFrom || at > orderOf(scan, deferred))) return e;
				}
			}
			continue;
		}
		if (refills(flow)) continue;
		const from = flow.node != null && scan.order.has(flow.node) ? flow.node : null;
		if (flow.antecedent != null) todo.push({ flow: flow.antecedent, anchor: from });
		let list: FlowList | null = flow.antecedents;
		while (list != null) {
			todo.push({ flow: list.flow, anchor: from });
			list = list.next;
		}
	}
	for (const f of visited) { clean.add(f); }
	return null;
}

function addOnce(ctx: CheckerContext, message: string, at: Node): void {
	for (const e of ctx.errors) {
		if (e.line == at.location.line && e.column == at.location.column && e.message == message) return;
	}
	addError(ctx, message, at.location.line, at.location.column);
}

function eventsOf(scan: MoveScan, sym: Symbol): HashMap<FlowNode, MoveEvent[]> {
	const out = new HashMap<FlowNode, MoveEvent[]>();
	for (const t of scan.moves) {
		if (t.sym != sym) continue;
		const at = t.at.flowNode!;
		const known = out.get(at);
		if (known != null) {
			known.push(t);
		} else {
			out.set(at, [t]);
		}
	}
	return out;
}

function report(ctx: CheckerContext, taker: MoveEvent, read: Node): void {
	const name = (taker.at.data as IdentifierData).name;
	const edge = ownedEdgeOf(taker.at.nodeType);
	const message = taker.owner && edge != null
		? `cannot copy '${name}': '${typeDisplayName(taker.at.nodeType)}' holds the unique owning edge '${typeDisplayName(edge)}' — make this its last use, pass it with 'move', or read it as a plain reference (read again at ${read.location.line}:${read.location.column})`
		: `cannot move '${name}': variable is still used after this point (read at ${read.location.line}:${read.location.column}); assign it a new value before reading it again`;
	addOnce(ctx, message, taker.at);
}

export function checkMovesIn(ctx: CheckerContext, root: Node | null): void {
	if (root == null) return;
	const scan = new MoveScan();
	collectMoves(root, scan, []);
	for (const f of scan.faults) {
		addOnce(ctx, `cannot move '${(f.at.data as IdentifierData).name}': ${f.why}`, f.at);
	}
	const locked = ctx.lockedMoves;
	ctx.lockedMoves = [];
	if (scan.moves.length == 0 && locked.length == 0) return;
	numberNodes(root, scan);
	checkLockedMoves(ctx, scan, locked);
	if (scan.moves.length == 0) return;
	const reported = new HashSet<Node>();
	for (const sym of scan.moved) {
		const reads = scan.reads.get(sym);
		if (reads == null) continue;
		const events = eventsOf(scan, sym);
		const clean = new HashSet<FlowNode>();
		for (const read of reads) {
			if (read.flowNode == null) continue;
			const taker = reachingMove(scan, read, events, clean, (flow: FlowNode): boolean =>
				(flow.flags.has(FlowFlag.Assignment) && declaresSym(flow.node, sym)) || (flow.flags.has(FlowFlag.Call) && writesOut(flow.node, sym)));
			if (taker == null || reported.has(taker.at)) continue;
			reported.add(taker.at);
			report(ctx, taker, read);
		}
	}
}

function pathBase(n: Node): Node | null {
	return match (n.kind) {
		NodeKind.MemberExpr => (n.data as MemberExprData).object,
		NodeKind.ArrayAccess => (n.data as ArrayAccessData).array,
		NodeKind.TypeAssertion => (n.data as TypeAssertionData).asExpr,
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => (n.data as HiddenDerefData).expr,
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => (n.data as HiddenStdConvData).convExpr,
		_ => null,
	};
}

function rootIdentOf(n: Node | null): Node | null {
	let at = n;
	while (at != null && at.kind != NodeKind.Identifier) at = pathBase(at);
	return at;
}

function pathText(n: Node): string {
	return match (n.kind) {
		NodeKind.Identifier => (n.data as IdentifierData).name,
		NodeKind.MemberExpr => pathText((n.data as MemberExprData).object) + "." + (n.data as MemberExprData).property,
		NodeKind.ArrayAccess => pathText((n.data as ArrayAccessData).array) + "[…]",
		_ => pathBase(n) != null ? pathText(pathBase(n)!) : "…",
	};
}

interface PathRead {
	ident: Node;
	at: Node;
	place: Place;
}

class LockWalk {
	scope: PlaceScope;
	moved: Place;
	skip: Node;
	syms = new HashSet<Symbol>();
	reads: PathRead[] = [];
	indexSyms = new HashSet<Symbol>();
	indexWrites: Node[] = [];
	constructor(scope: PlaceScope, moved: Place, skip: Node) {
		this.scope = scope;
		this.moved = moved;
		this.skip = skip;
		for (const s of moved.steps) {
			if (s.kind == StepKind.Index && s.indexSym != null) this.indexSyms.add(s.indexSym);
		}
	}
}

function writtenIndex(w: LockWalk, node: Node): Node | null {
	const target = match (node.kind) {
		NodeKind.UpdateExpr => (node.data as UpdateExprData).updateArg,
		NodeKind.BinaryExpr => isAssignOp((node.data as BinaryExprData).operator) ? (node.data as BinaryExprData).left : null,
		NodeKind.OutExpr => (node.data as OutExprData).outArg,
		_ => null,
	};
	const ident = target != null ? stripHidden(target) : null;
	return ident != null && ident.kind == NodeKind.Identifier && ident.resolvedSym != null && w.indexSyms.has(ident.resolvedSym) ? ident : null;
}

// A write to the moved place, or to a place that holds it, puts a value back.
function refillsPlace(w: LockWalk, target: Node | null): boolean {
	const p = placeOf(w.scope, target);
	if (p == null || p.root != w.moved.root) return false;
	const o = overlap(p, w.moved, false);
	return o == Overlap.Same || o == Overlap.Contains;
}

// The element store `xs[i] = v` after the checker turned it into `xs.[]=(i, v)`.
function refillsElement(w: LockWalk, call: Node): boolean {
	const d = call.data as CallExprData;
	if (d.callee.kind != NodeKind.MemberExpr || (d.callee.data as MemberExprData).property != "[]=" || d.arguments.length != 2) return false;
	const holder = placeOf(w.scope, (d.callee.data as MemberExprData).object);
	const moved = w.moved;
	if (holder == null || holder.root != moved.root || holder.steps.length + 1 != moved.steps.length) return false;
	const last = moved.steps[moved.steps.length - 1];
	if (last.kind != StepKind.Index || overlap(holder, moved, false) != Overlap.Contains) return false;
	const index = stripHidden(d.arguments[0]);
	if (index == null) return false;
	if (index.kind == NodeKind.Identifier) return last.indexSym != null && index.resolvedSym == last.indexSym;
	return index.kind == NodeKind.NumberLiteral && last.indexSym == null && (index.data as { intVal: int64 }).intVal == last.constant;
}

function refillAt(w: LockWalk, node: Node | null): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		return d.operator == "=" && refillsPlace(w, d.left);
	}
	return node.kind == NodeKind.CallExpr && refillsElement(w, node);
}

function walkLockReads(w: LockWalk, node: Node | null, outer: Node | null): void {
	if (node == null || node == w.skip) return;
	const index = writtenIndex(w, node);
	if (index != null) w.indexWrites.push(index);
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym == null || !w.syms.has(sym)) return;
		const at = outer ?? node;
		const place = placeOf(w.scope, at) ?? placeOf(w.scope, node);
		if (place != null && place.root == w.moved.root) w.reads.push({ ident: node, at, place });
		return;
	}
	if (node.kind == NodeKind.BinaryExpr && (node.data as BinaryExprData).operator == "=" && refillAt(w, node)) {
		walkTargetParts(w, (node.data as BinaryExprData).left);
		walkLockReads(w, (node.data as BinaryExprData).right, null);
		return;
	}
	if (node.kind == NodeKind.CallExpr && refillAt(w, node)) {
		walkTargetParts(w, ((node.data as CallExprData).callee.data as MemberExprData).object);
		for (const a of (node.data as CallExprData).arguments) walkLockReads(w, a, null);
		return;
	}
	const base = pathBase(node);
	forEachChild(node, (child: Node): void => { walkLockReads(w, child, child == base ? (outer ?? node) : null); });
}

// A refilled target is written, not read; only the indexes along it are read.
function walkTargetParts(w: LockWalk, target: Node | null): void {
	let at = target;
	while (at != null && at.kind != NodeKind.Identifier) {
		if (at.kind == NodeKind.ArrayAccess) walkLockReads(w, (at.data as ArrayAccessData).index, null);
		at = pathBase(at);
	}
}

function routineBodyNode(routine: Node): Node | null {
	if (routine.kind == NodeKind.TestDecl) return (routine.data as TestDeclData).testBody;
	return routineBody(routine);
}

function aliasesOf(w: LockWalk, node: Node | null): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier && node.resolvedSym != null && !w.syms.has(node.resolvedSym)) {
		const p = placeOf(w.scope, node);
		if (p != null && p.root == w.moved.root) w.syms.add(node.resolvedSym);
	}
	forEachChild(node, (child: Node): void => { aliasesOf(w, child); });
}

function checkLockedMoves(ctx: CheckerContext, scan: MoveScan, locked: LockedMove[]): void {
	for (const lm of locked) {
		const body = routineBodyNode(lm.routine);
		const scope = placeScope(lm.routine, body);
		const arg = (lm.move.data as MoveExprData).moveArg;
		const moved = placeOf(scope, arg);
		const event = rootIdentOf(arg);
		if (moved == null || moved.root == null || event == null || event.flowNode == null) continue;
		if (ctx.capturedSyms.has(moved.root)) {
			addOnce(ctx, `cannot move '${pathText(arg)}': a closure captures '${moved.root.name}', and the closure could read the moved slot before it is put back — move it out of a local the closure does not capture`, arg);
			continue;
		}
		const w = new LockWalk(scope, moved, lm.move);
		w.syms.add(moved.root);
		aliasesOf(w, body);
		walkLockReads(w, body, null);
		w.reads.push({ ident: event, at: arg, place: moved });
		const events = new HashMap<FlowNode, MoveEvent[]>();
		events.set(event.flowNode, [{ at: event, sym: moved.root, owner: false }]);
		const clean = new HashSet<FlowNode>();
		const refilled = (flow: FlowNode): boolean => flow.flags.has(FlowFlag.Assignment) && refillAt(w, flow.node);
		const written = w.indexWrites.find((ident) => ident.flowNode != null && reachingMove(scan, ident, events, clean, refilled) != null);
		if (written != null) {
			addOnce(ctx, `cannot write '${(written.data as IdentifierData).name}': '${pathText(arg)}' was moved out at ${lm.move.location.line}:${lm.move.location.column} and is not put back yet, and '${(written.data as IdentifierData).name}' says which element to put it back into — write '${pathText(arg)}' first`, written);
			continue;
		}
		for (const read of w.reads) {
			if (read.ident.flowNode == null || overlap(moved, read.place, true) == Overlap.Disjoint) continue;
			const taker = reachingMove(scan, read.ident, events, clean, refilled);
			if (taker == null) continue;
			const where = `${lm.move.location.line}:${lm.move.location.column}`;
			const message = overlap(moved, read.place, true) == Overlap.Contains
				? `cannot use '${pathText(read.at)}': '${pathText(arg)}' was moved out of it at ${where} and is not put back yet — put a value back into '${pathText(arg)}' first`
				: `cannot use '${pathText(read.at)}': '${pathText(arg)}' was moved out at ${where} and is not put back yet — write '${pathText(arg)}' first`;
			addOnce(ctx, message, read.at);
			break;
		}
	}
}
