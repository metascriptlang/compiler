import { Node, NodeKind, NodeFlag, ProgramData, FunctionDeclData, CallExprData, TryCatchStmtData, ExportDeclData, DecoratedDeclData, MacroInvocationData, ExprStmtData, VariableDeclData, ReturnStmtData, BinaryExprData, ObjectLiteralData, OutExprData, HiddenDerefData, Symbol, SymbolKind, TypeKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { hasFlag, SymbolFlag } from "./symbol";
import { dispatchEntryFor, dispatchOverridesFor } from "./context";

enum CallRaise { Never, Can, AsBody }

interface RoutineInfo {
	sym: Symbol;
	raises: boolean;
	callees: Symbol[];
}

let _raisesNothing: HashSet<Symbol> = new HashSet<Symbol>();
let _closureTargets: HashMap<Symbol, Symbol> = new HashMap<Symbol, Symbol>();
let _tempWrites: HashMap<Symbol, int32> = new HashMap<Symbol, int32>();

export function resetRaises(): void {
	_raisesNothing = new HashSet<Symbol>();
	_closureTargets = new HashMap<Symbol, Symbol>();
	_tempWrites = new HashMap<Symbol, int32>();
}

function closurePairTarget(value: Node | null): Symbol | null {
	if (value == null || value.kind != NodeKind.ObjectLiteral || !value.flags.has(NodeFlag.Closure)) return null;
	const d = value.data as ObjectLiteralData;
	for (let i = 0; i < d.keys.length; i += 1) {
		if (d.keys[i] != "fn") continue;
		const fn = d.properties[i];
		const sym = fn.resolvedSym;
		if (fn.kind == NodeKind.Identifier && sym != null && sym.symbolKind == SymbolKind.Function) return sym;
	}
	return null;
}

function tempOf(target: Node | null): Symbol | null {
	if (target == null || target.kind != NodeKind.Identifier) return null;
	const sym = target.resolvedSym;
	return sym != null && sym.symbolKind == SymbolKind.Temp ? sym : null;
}

function noteTempWrite(sym: Symbol, value: Node | null): void {
	const seen = _tempWrites.get(sym);
	_tempWrites.set(sym, seen == null ? 1 : seen + 1);
	const target = closurePairTarget(value);
	if (target != null) _closureTargets.set(sym, target);
}

function noteTempWrites(node: Node): void {
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (node.resolvedSym != null && node.resolvedSym!.symbolKind == SymbolKind.Temp && d.initializer != null && d.initializer.kind != NodeKind.NullLiteral) {
			noteTempWrite(node.resolvedSym!, d.initializer);
		}
	} else if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		const sym = tempOf(d.left);
		if (sym != null) noteTempWrite(sym, d.operator == "=" ? d.right : null);
	} else if (node.kind == NodeKind.OutExpr) {
		const sym = tempOf((node.data as OutExprData).outArg);
		if (sym != null) noteTempWrite(sym, null);
	} else if (node.kind == NodeKind.HiddenAddr) {
		const sym = tempOf((node.data as HiddenDerefData).expr);
		if (sym != null) noteTempWrite(sym, null);
	}
}

function calleeTarget(call: Readonly<Node>): Symbol | null {
	const sym = (call.data as CallExprData).callee.resolvedSym;
	if (sym == null) return null;
	const bound = _closureTargets.get(sym);
	return bound != null && _tempWrites.get(sym) == 1 ? bound : sym;
}

// A routine value handed to an extern can be called from inside it.
function passesRoutine(args: Readonly<Node[]>): boolean {
	for (const arg of args) {
		const t = arg.nodeType;
		if (t != null && t.kind == TypeKind.Function) return true;
	}
	return false;
}

function isDispatched(sym: Symbol): boolean {
	const entry = dispatchEntryFor(sym);
	if (entry == null) return false;
	return !entry.overloaded && dispatchOverridesFor(entry.classSym, entry.methodName).length > 0;
}

function classifyCall(call: Readonly<Node>): CallRaise {
	const cd = call.data as CallExprData;
	const sym = calleeTarget(call);
	if (sym == null) return CallRaise.Can;
	if (hasFlag(sym, SymbolFlag.Throws)) return CallRaise.Can;
	if (hasFlag(sym, SymbolFlag.GeneratedOp) || hasFlag(sym, SymbolFlag.DestroyOp) || hasFlag(sym, SymbolFlag.WasMovedOp)) return CallRaise.Never;
	if (hasFlag(sym, SymbolFlag.ImportC)) return passesRoutine(cd.arguments) ? CallRaise.Can : CallRaise.Never;
	if (hasFlag(sym, SymbolFlag.NeverRaises)) return CallRaise.Never;
	if (sym.symbolKind != SymbolKind.Function) return CallRaise.Can;
	if (hasFlag(sym, SymbolFlag.Async) || hasFlag(sym, SymbolFlag.StateMachine)) return CallRaise.Can;
	if (isDispatched(sym)) return CallRaise.Can;
	return CallRaise.AsBody;
}

function isNestedRoutine(node: Node): boolean {
	return node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction
		|| node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.ClassDecl
		|| node.kind == NodeKind.ActorDecl || node.kind == NodeKind.TestDecl;
}

function scanBody(node: Node, caught: boolean, info: RoutineInfo, routines: HashMap<Symbol, RoutineInfo>): void {
	if (node == null || isNestedRoutine(node)) return;
	if (node.kind == NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		scanBody(d.tryBody, caught || d.hasCatchClause, info, routines);
		if (d.hasCatchClause) scanBody(d.catchBody, caught, info, routines);
		scanBody(d.finallyBody, caught, info, routines);
		return;
	}
	if (!caught) {
		if (node.kind == NodeKind.ThrowStmt || node.kind == NodeKind.NewExpr
			|| node.kind == NodeKind.AwaitExpr || node.kind == NodeKind.YieldExpr) {
			info.raises = true;
		} else if (node.kind == NodeKind.MacroInvocation && (node.data as MacroInvocationData).macroName == "emit") {
			info.raises = true;
		} else if (node.kind == NodeKind.CallExpr) {
			const verdict = classifyCall(node);
			const callee = calleeTarget(node);
			if (verdict == CallRaise.Can) info.raises = true;
			else if (verdict == CallRaise.AsBody) {
				if (routines.has(callee!)) info.callees.push(callee!);
				else info.raises = true;
			}
		}
	}
	forEachChild(node, (child: Node): void => { scanBody(child, caught, info, routines); });
}

function collectRoutines(node: Node, found: Node[]): void {
	if (node == null) return;
	noteTempWrites(node);
	if (node.kind == NodeKind.FunctionDecl && node.resolvedSym != null && (node.data as FunctionDeclData).fnBody != null) {
		found.push(node);
	}
	if (node.kind == NodeKind.ExportDecl) {
		collectRoutines((node.data as ExportDeclData).exportedDecl, found);
		return;
	}
	if (node.kind == NodeKind.DecoratedDecl) {
		collectRoutines((node.data as DecoratedDeclData).decoratedNode, found);
		return;
	}
	forEachChild(node, (child: Node): void => { collectRoutines(child, found); });
}

export function inferRaises(programs: Node[]): void {
	resetRaises();
	const decls: Node[] = [];
	for (const program of programs) {
		if (program == null) continue;
		for (const stmt of (program.data as ProgramData).programStmts) collectRoutines(stmt, decls);
	}
	const routines = new HashMap<Symbol, RoutineInfo>();
	const order: RoutineInfo[] = [];
	const bodies: Node[] = [];
	for (const decl of decls) {
		const sym = decl.resolvedSym!;
		const seen = routines.get(sym);
		if (seen != null) {
			seen.raises = true;
			continue;
		}
		const info: RoutineInfo = { sym: sym, raises: false, callees: [] };
		routines.set(sym, info);
		order.push(info);
		bodies.push((decl.data as FunctionDeclData).fnBody);
	}
	for (let i = 0; i < order.length; i += 1) scanBody(bodies[i], false, order[i], routines);
	const callers = new HashMap<Symbol, RoutineInfo[]>();
	for (const info of order) {
		for (const callee of info.callees) {
			const list = callers.get(callee);
			if (list != null) list.push(info);
			else callers.set(callee, [info]);
		}
	}
	const pending: RoutineInfo[] = [];
	for (const info of order) {
		if (info.raises) pending.push(info);
	}
	while (pending.length > 0) {
		const done = pending.pop()!;
		const list = callers.get(done.sym);
		if (list == null) continue;
		for (const caller of list) {
			if (caller.raises) continue;
			caller.raises = true;
			pending.push(caller);
		}
	}
	for (const info of order) {
		if (!info.raises) _raisesNothing.add(info.sym);
	}
	for (const program of programs) {
		if (program != null) markStatementValues(program);
	}
}

function holdsRaisingCall(expr: Node): boolean {
	if (expr == null || isNestedRoutine(expr)) return false;
	if (expr.kind == NodeKind.CallExpr && callCanRaise(expr)) return true;
	let found = false;
	forEachChild(expr, (child: Node): void => {
		if (!found && holdsRaisingCall(child)) found = true;
	});
	return found;
}

function markValue(value: Node | null): void {
	if (value == null) return;
	const raises = holdsRaisingCall(value);
	value.flags = value.flags.excl(raises ? NodeFlag.CannotRaise : NodeFlag.CanRaise).incl(raises ? NodeFlag.CanRaise : NodeFlag.CannotRaise);
}

function markStatementValues(node: Node): void {
	if (node == null) return;
	if (node.kind == NodeKind.ExprStmt) markValue((node.data as ExprStmtData).expr);
	else if (node.kind == NodeKind.VariableDecl) markValue((node.data as VariableDeclData).initializer);
	else if (node.kind == NodeKind.ReturnStmt) markValue((node.data as ReturnStmtData).argument);
	forEachChild(node, (child: Node): void => { markStatementValues(child); });
}

export function callCanRaise(call: Readonly<Node>): boolean {
	const verdict = classifyCall(call);
	if (verdict == CallRaise.AsBody) return !_raisesNothing.has(calleeTarget(call)!);
	return verdict == CallRaise.Can;
}

// A value the inference never saw keeps the check after a top-level call.
export function statementCanRaise(value: Readonly<Node>): boolean {
	if (value == null) return false;
	if (value.flags.has(NodeFlag.CanRaise)) return true;
	if (value.flags.has(NodeFlag.CannotRaise)) return false;
	if (value.kind == NodeKind.CallExpr) return true;
	if (value.kind != NodeKind.BinaryExpr) return false;
	const d = value.data as BinaryExprData;
	return d.operator == "=" && d.right != null && d.right.kind == NodeKind.CallExpr;
}
