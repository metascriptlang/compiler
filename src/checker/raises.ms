import { Node, NodeKind, NodeFlag, ProgramData, FunctionDeclData, CallExprData, NewExprData, TryCatchStmtData, MacroInvocationData, ExprStmtData, VariableDeclData, ReturnStmtData, BinaryExprData, ObjectLiteralData, OutExprData, HiddenDerefData, Symbol, SymbolKind, TypeKind } from "../ast/node";
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
let _routines: HashMap<Symbol, RoutineInfo> = new HashMap<Symbol, RoutineInfo>();
let _order: RoutineInfo[] = [];
let _siteInfos: RoutineInfo[] = [];
let _siteNodes: Node[] = [];
let _statementValues: Node[] = [];
let _walkInfo: RoutineInfo | null = null;
let _walkCaught = false;
let _holdFound = false;

export function resetRaises(): void {
	_raisesNothing = new HashSet<Symbol>();
	_closureTargets = new HashMap<Symbol, Symbol>();
	_tempWrites = new HashMap<Symbol, int32>();
}

function closurePairTarget(value: Readonly<Node> | null): Symbol | null {
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
	const callee = (call.data as CallExprData).callee;
	const sym = callee.resolvedSym;
	if (sym == null) return closurePairTarget(callee);
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
	return classifyTarget(calleeTarget(call), (call.data as CallExprData).arguments);
}

// A `new` runs the constructor routine, so it raises as that routine does; one with no routine symbol keeps the check.
function classifyNew(node: Readonly<Node>): CallRaise {
	const sym = node.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.ClassInit)) return CallRaise.Can;
	return classifyTarget(sym, (node.data as NewExprData).newArguments);
}

function classifyTarget(sym: Symbol | null, args: Readonly<Node[]>): CallRaise {
	if (sym == null) return CallRaise.Can;
	if (hasFlag(sym, SymbolFlag.Throws)) return CallRaise.Can;
	if (hasFlag(sym, SymbolFlag.GeneratedOp) || hasFlag(sym, SymbolFlag.DestroyOp) || hasFlag(sym, SymbolFlag.WasMovedOp)) return CallRaise.Never;
	if (hasFlag(sym, SymbolFlag.ImportC)) return passesRoutine(args) ? CallRaise.Can : CallRaise.Never;
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

function noteVerdict(verdict: CallRaise, callee: Symbol | null, info: RoutineInfo): void {
	if (verdict == CallRaise.Can) info.raises = true;
	else if (verdict == CallRaise.AsBody) {
		if (_routines.has(callee!)) info.callees.push(callee!);
		else info.raises = true;
	}
}

function resetWalk(): void {
	_routines = new HashMap<Symbol, RoutineInfo>();
	_order = [];
	_siteInfos = [];
	_siteNodes = [];
	_statementValues = [];
	_walkInfo = null;
	_walkCaught = false;
}

function routineOf(node: Node): RoutineInfo | null {
	if (node.kind != NodeKind.FunctionDecl || node.resolvedSym == null || (node.data as FunctionDeclData).fnBody == null) return null;
	const sym = node.resolvedSym!;
	const seen = _routines.get(sym);
	if (seen != null) {
		seen.raises = true;
		return null;
	}
	const info: RoutineInfo = { sym: sym, raises: false, callees: [] };
	_routines.set(sym, info);
	_order.push(info);
	return info;
}

function noteStatementValue(node: Node): void {
	let value: Node | null = null;
	if (node.kind == NodeKind.ExprStmt) value = (node.data as ExprStmtData).expr;
	else if (node.kind == NodeKind.VariableDecl) value = (node.data as VariableDeclData).initializer;
	else if (node.kind == NodeKind.ReturnStmt) value = (node.data as ReturnStmtData).argument;
	if (value != null) _statementValues.push(value);
}

function walkTry(node: Node, info: RoutineInfo): void {
	const d = node.data as TryCatchStmtData;
	const caught = _walkCaught;
	_walkCaught = caught || d.hasCatchClause;
	walkProgram(d.tryBody);
	_walkCaught = caught;
	if (d.hasCatchClause) walkProgram(d.catchBody);
	else {
		_walkInfo = null;
		walkProgram(d.catchBody);
		_walkInfo = info;
	}
	walkProgram(d.finallyBody);
}

function noteRaiseSite(node: Node, info: RoutineInfo): void {
	if (node.kind == NodeKind.ThrowStmt || node.kind == NodeKind.AwaitExpr || node.kind == NodeKind.YieldExpr) {
		info.raises = true;
	} else if (node.kind == NodeKind.MacroInvocation && (node.data as MacroInvocationData).macroName == "emit") {
		info.raises = true;
	} else if (node.kind == NodeKind.NewExpr || node.kind == NodeKind.CallExpr) {
		_siteInfos.push(info);
		_siteNodes.push(node);
	}
}

function walkProgram(node: Node): void {
	if (node == null) return;
	noteTempWrites(node);
	noteStatementValue(node);
	const info = _walkInfo;
	if (isNestedRoutine(node)) {
		const caught = _walkCaught;
		_walkInfo = routineOf(node);
		_walkCaught = false;
		forEachChild(node, walkProgram);
		_walkInfo = info;
		_walkCaught = caught;
		return;
	}
	if (info != null) {
		if (node.kind == NodeKind.TryCatchStmt) {
			walkTry(node, info);
			return;
		}
		if (!_walkCaught) noteRaiseSite(node, info);
	}
	forEachChild(node, walkProgram);
}

function noteSiteVerdict(node: Node, info: RoutineInfo): void {
	if (node.kind == NodeKind.NewExpr) {
		noteVerdict(classifyNew(node), node.resolvedSym, info);
		return;
	}
	const callee = calleeTarget(node);
	noteVerdict(classifyTarget(callee, (node.data as CallExprData).arguments), callee, info);
}

export function inferRaises(programs: Node[]): void {
	resetRaises();
	resetWalk();
	for (const program of programs) {
		if (program == null) continue;
		for (const stmt of (program.data as ProgramData).programStmts) walkProgram(stmt);
	}
	for (let i = 0; i < _siteNodes.length; i += 1) noteSiteVerdict(_siteNodes[i], _siteInfos[i]);
	const callers = new HashMap<Symbol, RoutineInfo[]>();
	for (const info of _order) {
		for (const callee of info.callees) {
			const list = callers.get(callee);
			if (list != null) list.push(info);
			else callers.set(callee, [info]);
		}
	}
	const pending: RoutineInfo[] = [];
	for (const info of _order) {
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
	for (const info of _order) {
		if (!info.raises) _raisesNothing.add(info.sym);
	}
	for (const value of _statementValues) markValue(value);
	resetWalk();
}

function holdStep(expr: Node): void {
	if (_holdFound || expr == null || isNestedRoutine(expr)) return;
	if ((expr.kind == NodeKind.CallExpr && callCanRaise(expr)) || (expr.kind == NodeKind.NewExpr && newCanRaise(expr))) {
		_holdFound = true;
		return;
	}
	forEachChild(expr, holdStep);
}

function markValue(value: Node): void {
	_holdFound = false;
	holdStep(value);
	const raises = _holdFound;
	value.flags = value.flags.excl(raises ? NodeFlag.CannotRaise : NodeFlag.CanRaise).incl(raises ? NodeFlag.CanRaise : NodeFlag.CannotRaise);
}

export function callCanRaise(call: Readonly<Node>): boolean {
	const verdict = classifyCall(call);
	if (verdict == CallRaise.AsBody) return !_raisesNothing.has(calleeTarget(call)!);
	return verdict == CallRaise.Can;
}

export function newCanRaise(node: Readonly<Node>): boolean {
	const verdict = classifyNew(node);
	if (verdict == CallRaise.AsBody) return !_raisesNothing.has(node.resolvedSym!);
	return verdict == CallRaise.Can;
}

// A value the inference never saw keeps the check after a top-level call.
export function statementCanRaise(value: Readonly<Node>): boolean {
	if (value == null) return false;
	if (value.flags.has(NodeFlag.CanRaise)) return true;
	if (value.flags.has(NodeFlag.CannotRaise)) return false;
	if (value.kind == NodeKind.CallExpr || value.kind == NodeKind.NewExpr) return true;
	if (value.kind != NodeKind.BinaryExpr) return false;
	const d = value.data as BinaryExprData;
	return d.operator == "=" && d.right != null && d.right.kind == NodeKind.CallExpr;
}

// True when running the body can neither set nor observe the error flag: every call is a
// never-raising runtime or lifecycle routine and nothing throws, awaits, nests a try or jumps out
// (a jump out of a finally drops the exception in flight, which the error scaffold clears).
export function bodyIsErrorBlind(node: Node | null): boolean {
	if (node == null || isNestedRoutine(node)) return true;
	match (node.kind) {
		NodeKind.ThrowStmt | NodeKind.NewExpr | NodeKind.AwaitExpr | NodeKind.YieldExpr
			| NodeKind.TryCatchStmt | NodeKind.MacroInvocation
			| NodeKind.ReturnStmt | NodeKind.BreakStmt | NodeKind.ContinueStmt => { return false; },
		NodeKind.CallExpr => { if (classifyCall(node) != CallRaise.Never) return false; },
		_ => {},
	};
	let blind = true;
	forEachChild(node, (child: Node): void => { if (blind && !bodyIsErrorBlind(child)) blind = false; });
	return blind;
}

// Marks each finally block that runs without touching the error flag, so codegen reads the verdict
// off a node it only holds read-only.
export function markErrorBlindFinallies(node: Node | null): void {
	if (node == null) return;
	if (node.kind == NodeKind.TryCatchStmt) {
		const fin = (node.data as TryCatchStmtData).finallyBody;
		if (fin != null && bodyIsErrorBlind(fin)) fin.flags = fin.flags.incl(NodeFlag.CannotRaise);
	}
	forEachChild(node, (child: Node): void => { markErrorBlindFinallies(child); });
}

export function finallyIsErrorBlind(fin: Readonly<Node>): boolean {
	return fin.flags.has(NodeFlag.CannotRaise);
}
