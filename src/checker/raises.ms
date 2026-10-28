import { AttachedOp, Node, NodeKind, NodeFlag, ProgramData, FunctionDeclData, CallExprData, NewExprData, TryCatchStmtData, MacroInvocationData, ExprStmtData, VariableDeclData, ReturnStmtData, BinaryExprData, ObjectLiteralData, OutExprData, HiddenDerefData, Symbol, SymbolKind, Type, TypeKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { hasFlag, SymbolFlag } from "./symbol";
import { dispatchEntryFor, dispatchOverridesFor } from "./context";
import { getOpByKeyIn, hookOps } from "../codegen/c/types";
import { buildModuleNameRoots, ModuleNameRoots } from "../codegen/c/names";

enum CallRaise { Never, Can, AsBody }

interface RoutineInfo {
	id: int32;
	sym: Symbol;
	raises: boolean;
	callers: int32[];
}

interface RaiseTables {
	raisesNothing: HashSet<Symbol>;
	closureTargets: HashMap<Symbol, Cursor<Readonly<Symbol>>>;
	tempWrites: HashMap<Symbol, int32>;
	bodies: HashSet<Symbol>;
	ops: HashMap<string, Symbol>;
	roots: ModuleNameRoots;
}

function freshRaiseTables(ops: HashMap<string, Symbol>, roots: ModuleNameRoots): RaiseTables {
	return {
		raisesNothing: new HashSet<Symbol>(),
		closureTargets: new HashMap<Symbol, Cursor<Readonly<Symbol>>>(),
		tempWrites: new HashMap<Symbol, int32>(),
		bodies: new HashSet<Symbol>(),
		ops: ops,
		roots: roots,
	};
}

let _tables: RaiseTables = freshRaiseTables(new HashMap<string, Symbol>(), { compiler: "", packages: "", project: "", uniqueNames: new HashMap<string, string>() });
let _routines: HashMap<Symbol, RoutineInfo> = new HashMap<Symbol, RoutineInfo>();
let _order: RoutineInfo[] = [];
let _statementValues: Node[] = [];
let _valueParents: int32[] = [];
let _valueRaises: boolean[] = [];
let _openValue: int32 = -1;
let _calls: Node[] = [];
let _callOwners: int32[] = [];
let _callValues: int32[] = [];
let _callTargets: int32[] = [];
let _callVerdicts: CallRaise[] = [];
let _walkInfo: RoutineInfo | null = null;
let _walkCaught = false;
let _holdFound = false;
let _blindBroken = false;

export function resetRaises(): void {
	_tables = freshRaiseTables(hookOps(), buildModuleNameRoots());
}

function closurePairTarget(value: Readonly<Node> | null): Readonly<Symbol | null> {
	if (value == null || value.kind != NodeKind.ObjectLiteral || !value.flags.has(NodeFlag.Closure)) return null;
	const d = value.data as ObjectLiteralData;
	for (let i = 0; i < d.keys.length; i += 1) {
		if (d.keys[i] != "fn") continue;
		const fn = d.properties[i];
		const sym = fn.resolvedSym;
		if (fn.kind == NodeKind.Identifier && sym != null && sym.symbolKind == SymbolKind.Function) return (value.data as ObjectLiteralData).properties[i].resolvedSym;
	}
	return null;
}

function tempOf(target: Node | null): Symbol | null {
	if (target == null || target.kind != NodeKind.Identifier) return null;
	const sym = target.resolvedSym;
	return sym != null && tracksWrites(sym) ? sym : null;
}

function tracksWrites(sym: Readonly<Symbol>): boolean {
	return sym.symbolKind == SymbolKind.Temp || sym.symbolKind == SymbolKind.Variable;
}

function noteTempWrite(sym: Symbol, value: Node | null): void {
	const seen = _tables.tempWrites.get(sym);
	_tables.tempWrites.set(sym, seen == null ? 1 : seen + 1);
	const target = closurePairTarget(value);
	if (target != null) _tables.closureTargets.set(sym, target);
}

function noteTempWrites(node: Node): void {
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (node.resolvedSym != null && tracksWrites(node.resolvedSym!) && d.initializer != null && d.initializer.kind != NodeKind.NullLiteral) {
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

function calleeTarget(tables: Readonly<RaiseTables>, call: Readonly<Node>): Readonly<Symbol | null> {
	const sym = (call.data as CallExprData).callee.resolvedSym;
	if (sym == null) return closurePairTarget((call.data as CallExprData).callee);
	if (hasFlag(sym, SymbolFlag.DestroyOp)) return destroyRoutine(tables, (call.data as CallExprData).callee.resolvedSym!, (call.data as CallExprData).arguments) ?? (call.data as CallExprData).callee.resolvedSym;
	if (isOverloadSignature(sym)) return implementationOf(call);
	const bound = tables.closureTargets.readonlyGet(sym);
	return bound != null && tables.tempWrites.readonlyGet(sym) == 1 ? tables.closureTargets.readonlyGet((call.data as CallExprData).callee.resolvedSym!) : (call.data as CallExprData).callee.resolvedSym;
}

function isOverloadSignature(sym: Readonly<Symbol>): boolean {
	return hasFlag(sym, SymbolFlag.OverloadSig) && !hasFlag(sym, SymbolFlag.ImportC);
}

function implementationOf(call: Readonly<Node>): Readonly<Symbol | null> {
	return call.resolvedSym != null && !isOverloadSignature(call.resolvedSym) ? call.resolvedSym : null;
}

// A routine value handed to an extern can be called from inside it.
function passesRoutine(args: Readonly<Node[]>): boolean {
	for (const arg of args) {
		const t = arg.nodeType;
		if (t != null && t.kind == TypeKind.Function) return true;
	}
	return false;
}

function isDispatched(sym: Readonly<Symbol>): boolean {
	const entry = dispatchEntryFor(sym);
	if (entry == null) return false;
	return !entry.overloaded && dispatchOverridesFor(entry.classSym, entry.methodName).length > 0;
}

// A destroy raises as the routine it runs: a lifted or user destroy by its own body, a runtime
// release by the destroy lifted for the released type. One with no body to read never raises.
function destroyRoutine(tables: Readonly<RaiseTables>, sym: Readonly<Symbol>, args: Readonly<Node[]>): Readonly<Symbol | null> {
	if (tables.bodies.has(sym) && !hasFlag(sym, SymbolFlag.ImportC)) return sym;
	if (args.length == 0 || args[0].nodeType == null) return null;
	return withBody(tables.bodies, releasedTypeDestroy(tables.ops, tables.roots, args[0].nodeType!));
}

function withBody(bodies: Readonly<HashSet<Symbol>>, op: Readonly<Symbol | null>): Readonly<Symbol | null> {
	return op != null && bodies.has(op) ? op : null;
}

// A class value is a ref whose destroy is lifted for the object it points at.
function releasedTypeDestroy(ops: Readonly<HashMap<string, Symbol>>, roots: Readonly<ModuleNameRoots>, t: Readonly<Type>): Readonly<Symbol | null> {
	return ownOrPointee(getOpByKeyIn(ops, roots, t, AttachedOp.AttachedDestructor), ops, roots, t);
}

function ownOrPointee(own: Readonly<Symbol | null>, ops: Readonly<HashMap<string, Symbol>>, roots: Readonly<ModuleNameRoots>, t: Readonly<Type>): Readonly<Symbol | null> {
	if (own != null || t.kind != TypeKind.Ref || t.typeReturn == null) return own;
	return getOpByKeyIn(ops, roots, t.typeReturn!, AttachedOp.AttachedDestructor);
}

function classifyCall(call: Readonly<Node>): CallRaise {
	return classifyTarget(calleeTarget(_tables, call), (call.data as CallExprData).arguments);
}

// A `new` runs the constructor routine, so it raises as that routine does; one with no routine symbol keeps the check.
function classifyNew(node: Readonly<Node>): CallRaise {
	const sym = node.resolvedSym;
	if (sym == null || !hasFlag(sym, SymbolFlag.ClassInit)) return CallRaise.Can;
	return classifyTarget(sym, (node.data as NewExprData).newArguments);
}

function classifyTarget(sym: Readonly<Symbol | null>, args: Readonly<Node[]>): CallRaise {
	if (sym == null) return CallRaise.Can;
	if (hasFlag(sym, SymbolFlag.Throws)) return CallRaise.Can;
	if (hasFlag(sym, SymbolFlag.DestroyOp)) return destroyRoutine(_tables, sym, args) != null ? CallRaise.AsBody : CallRaise.Never;
	if (hasFlag(sym, SymbolFlag.GeneratedOp) || hasFlag(sym, SymbolFlag.WasMovedOp)) return CallRaise.Never;
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

function noteVerdict(verdict: CallRaise, target: int32, owner: int32): void {
	if (verdict == CallRaise.Can) _order[owner].raises = true;
	else if (verdict == CallRaise.AsBody) {
		if (target >= 0) _order[target].callers.push(owner);
		else _order[owner].raises = true;
	}
}

function resetWalk(): void {
	_routines = new HashMap<Symbol, RoutineInfo>();
	_order = [];
	_statementValues = [];
	_valueParents = [];
	_valueRaises = [];
	_openValue = -1;
	_calls = [];
	_callOwners = [];
	_callValues = [];
	_callTargets = [];
	_callVerdicts = [];
	_walkInfo = null;
	_walkCaught = false;
}

function routineOf(node: Node): RoutineInfo | null {
	if (node.kind != NodeKind.FunctionDecl || node.resolvedSym == null || (node.data as FunctionDeclData).fnBody == null) return null;
	const sym = node.resolvedSym!;
	if (isOverloadSignature(sym)) return null;
	const seen = _routines.get(sym);
	if (seen != null) {
		seen.raises = true;
		return null;
	}
	const info: RoutineInfo = { id: _order.length, sym: sym, raises: false, callers: [] };
	_routines.set(sym, info);
	_order.push(info);
	return info;
}

function statementValueOf(node: Node): Node | null {
	if (node.kind == NodeKind.ExprStmt) return (node.data as ExprStmtData).expr;
	if (node.kind == NodeKind.VariableDecl) return (node.data as VariableDeclData).initializer;
	if (node.kind == NodeKind.ReturnStmt) return (node.data as ReturnStmtData).argument;
	return null;
}

// A statement holds its value as its only child, so the value stays open for the statement's subtree
// and each call inside records the innermost open value; a raising call then marks the chain of values
// around it, so no value's subtree is walked a second time.
function openStatementValue(node: Node): void {
	const value = statementValueOf(node);
	if (value == null) return;
	_valueParents.push(_openValue);
	_valueRaises.push(false);
	_statementValues.push(value);
	_openValue = _statementValues.length - 1;
}

function noteCall(node: Node, info: RoutineInfo | null): void {
	if (node.kind != NodeKind.CallExpr && node.kind != NodeKind.NewExpr) return;
	_calls.push(node);
	_callValues.push(_openValue);
	_callOwners.push(info != null && !_walkCaught ? info.id : -1);
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
	}
}

function walkProgram(node: Node): void {
	if (node == null) return;
	const info = _walkInfo;
	const outerValue = _openValue;
	noteTempWrites(node);
	openStatementValue(node);
	noteCall(node, info);
	if (isNestedRoutine(node)) {
		const caught = _walkCaught;
		_walkInfo = routineOf(node);
		_walkCaught = false;
		_openValue = -1;
		forEachChild(node, walkProgram);
		_walkInfo = info;
		_walkCaught = caught;
	} else if (info != null && node.kind == NodeKind.TryCatchStmt) {
		walkTry(node, info);
	} else {
		if (info != null && !_walkCaught) noteRaiseSite(node, info);
		forEachChild(node, walkProgram);
	}
	_openValue = outerValue;
}

function classifyWalkedCalls(): void {
	for (let i = 0; i < _calls.length; i += 1) {
		const call = _calls[i];
		const isNew = call.kind == NodeKind.NewExpr;
		const callee = isNew ? call.resolvedSym : calleeTarget(_tables, call);
		const verdict = isNew ? classifyNew(call) : classifyTarget(callee, (call.data as CallExprData).arguments);
		const target = verdict == CallRaise.AsBody ? _routines.get(callee!) : null;
		_callVerdicts.push(verdict);
		_callTargets.push(target != null ? target.id : -1);
		if (_callOwners[i] >= 0) noteVerdict(verdict, _callTargets[i], _callOwners[i]);
	}
}

function raiseValue(index: int32): void {
	let v = index;
	while (v >= 0 && !_valueRaises[v]) {
		_valueRaises[v] = true;
		v = _valueParents[v];
	}
}

function markWalkedCalls(): void {
	for (let i = 0; i < _calls.length; i += 1) {
		const verdict = _callVerdicts[i];
		const target = _callTargets[i];
		const raises = verdict == CallRaise.Can || (verdict == CallRaise.AsBody && (target < 0 || _order[target].raises));
		_calls[i].flags = _calls[i].flags.incl(raises ? NodeFlag.RaisingCall : NodeFlag.NonRaisingCall);
		if (raises) raiseValue(_callValues[i]);
	}
	for (let i = 0; i < _statementValues.length; i += 1) {
		const value = _statementValues[i];
		const raises = _valueRaises[i];
		value.flags = value.flags.excl(raises ? NodeFlag.CannotRaise : NodeFlag.CanRaise).incl(raises ? NodeFlag.CanRaise : NodeFlag.CannotRaise);
	}
}

export function markEveryBodyMayRaise(programs: Node[]): void {
	resetRaises();
	resetWalk();
	for (const program of programs) collectMarkSites(program);
	for (const call of _calls) markCall(call);
	for (const value of _statementValues) markValue(value);
	resetWalk();
}

function collectMarkSites(node: Node): void {
	if (node == null) return;
	const value = statementValueOf(node);
	if (value != null) _statementValues.push(value);
	if (node.kind == NodeKind.CallExpr || node.kind == NodeKind.NewExpr) _calls.push(node);
	forEachChild(node, collectMarkSites);
}

export function inferRaises(programs: Node[]): void {
	resetRaises();
	resetWalk();
	for (const program of programs) {
		if (program == null) continue;
		for (const stmt of (program.data as ProgramData).programStmts) walkProgram(stmt);
	}
	for (const info of _order) _tables.bodies.add(info.sym);
	classifyWalkedCalls();
	const pending: RoutineInfo[] = [];
	for (const info of _order) {
		if (info.raises) pending.push(info);
	}
	while (pending.length > 0) {
		const done = pending.pop()!;
		for (const callerId of done.callers) {
			const caller = _order[callerId];
			if (caller.raises) continue;
			caller.raises = true;
			pending.push(caller);
		}
	}
	for (const info of _order) {
		if (!info.raises) _tables.raisesNothing.add(info.sym);
	}
	markWalkedCalls();
	resetWalk();
}

function holdStep(expr: Node): void {
	if (_holdFound || expr == null || isNestedRoutine(expr)) return;
	if ((expr.kind == NodeKind.CallExpr || expr.kind == NodeKind.NewExpr) && inferredCallRaises(expr)) {
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

function markCall(call: Node): void {
	const raises = call.kind == NodeKind.CallExpr ? callCanRaise(call) : newCanRaise(call);
	call.flags = call.flags.incl(raises ? NodeFlag.RaisingCall : NodeFlag.NonRaisingCall);
}

export function callCanRaise(call: Readonly<Node>): boolean {
	const target = calleeTarget(_tables, call);
	const verdict = classifyTarget(target, (call.data as CallExprData).arguments);
	if (verdict == CallRaise.AsBody) return !_tables.raisesNothing.has(target!);
	return verdict == CallRaise.Can;
}

export function newCanRaise(node: Readonly<Node>): boolean {
	const verdict = classifyNew(node);
	if (verdict == CallRaise.AsBody) return !_tables.raisesNothing.has(node.resolvedSym!);
	return verdict == CallRaise.Can;
}

// The verdict the inference left on a call or `new`, so emission reads it instead of asking again.
export function inferredCallRaises(call: Readonly<Node>): boolean {
	if (call.flags.has(NodeFlag.RaisingCall)) return true;
	if (call.flags.has(NodeFlag.NonRaisingCall)) return false;
	throw new Error(`internal: a call at ${call.location.line}:${call.location.column} reached emission without a raises verdict`);
}

export function callMayRaise(call: Readonly<Node>): boolean {
	return classifyCall(call) != CallRaise.Never;
}

export function newMayRaise(node: Readonly<Node>): boolean {
	return classifyNew(node) != CallRaise.Never;
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
	_blindBroken = false;
	blindStep(node);
	return !_blindBroken;
}

function blindStep(node: Node | null): void {
	if (_blindBroken || node == null || isNestedRoutine(node)) return;
	match (node.kind) {
		NodeKind.ThrowStmt | NodeKind.NewExpr | NodeKind.AwaitExpr | NodeKind.YieldExpr
			| NodeKind.TryCatchStmt | NodeKind.MacroInvocation
			| NodeKind.ReturnStmt | NodeKind.BreakStmt | NodeKind.ContinueStmt => { _blindBroken = true; return; },
		NodeKind.CallExpr => { if (classifyCall(node) != CallRaise.Never && !destroyRaisesNothing(node)) { _blindBroken = true; return; } },
		_ => {},
	};
	forEachChild(node, blindStep);
}

function destroyRaisesNothing(call: Readonly<Node>): boolean {
	const sym = (call.data as CallExprData).callee.resolvedSym;
	return sym != null && hasFlag(sym, SymbolFlag.DestroyOp) && _tables.raisesNothing.has(calleeTarget(_tables, call)!);
}

// Marks each finally block that runs without touching the error flag, so codegen reads the verdict
// off a node it only holds read-only.
export function markErrorBlindFinallies(node: Node | null): void {
	if (node == null) return;
	if (node.kind == NodeKind.TryCatchStmt) {
		const fin = (node.data as TryCatchStmtData).finallyBody;
		if (fin != null && bodyIsErrorBlind(fin)) fin.flags = fin.flags.incl(NodeFlag.CannotRaise);
	}
	forEachChild(node, markErrorBlindFinallies);
}

export function finallyIsErrorBlind(fin: Readonly<Node>): boolean {
	return fin.flags.has(NodeFlag.CannotRaise);
}
