// Actor sendability + this-write isolation rules. Leaf module: no calls out.

import { ActorDeclData, ArrayAccessData, ArrayLiteralData, ArrowFunctionData, AwaitExprData, BinaryExprData, CallExprData, ConditionalExprData, ConstructorDeclData, DecoratedDeclData, DestructuringDeclData, ForOfStmtData, FunctionDeclData, FunctionExprData, HiddenDerefData, HiddenStdConvData, IdentifierData, MacroInvocationData, MatchCaseData, MatchExprData, MemberExprData, MethodDeclData, MoveExprData, NewExprData, Node, NodeKind, ObjectLiteralData, OutExprData, PropertyDeclData, SourceLocation, SpreadExprData, Symbol, SymbolKind, TestDeclData, TryExprData, Type, TypeAssertionData, TypeKind, UpdateExprData, VariableDeclData, YieldExprData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";
import { SymbolFlag, hasFlag, lookupSymbol } from "./symbol";
import { createArray, createGenericParam, createRef, createStruct, int32Type, isPrimitiveKind, isStructType, isAtomicRef, stringType, typeCarriesRef, typeDisplayName } from "./types";

export function hasNonisolatedField(actorSym: Symbol, fieldName: string): boolean {
	for (const n of actorSym.nonisolatedFields) {
		if (n == fieldName) return true;
	}
	return false;
}

// The three boundary rules below are ONE deep walk with three leaf policies.
// Every rule accepts the same structure — primitives, and structs / tuples /
// generic instances recursively — and a Ref or a Function is never data, so
// what actually distinguishes them is which leaves they admit. Keeping the
// walk in one place makes those differences the only thing to read, and stops
// a fourth rule from arriving as a fourth copy of the traversal.
enum SendLeaf {
	String = 1,        // owns memory, but a message COPIES it (msMsgSetString)
	Array = 2,         // ownership can travel with a MOVE; aliasing it cannot
	GenericParam = 4,  // unknowable here — re-checked at instantiation
}

function isDeepSendable(t: Type | null, leaves: int32): boolean {
	if (t == null) return true;
	if (isPrimitiveKind(t.kind)) return true;
	return match (t.kind) {
		TypeKind.String => (leaves & SendLeaf.String) != 0,
		TypeKind.GenericParam => (leaves & SendLeaf.GenericParam) != 0,
		TypeKind.Array => (leaves & SendLeaf.Array) != 0
			&& (t.typeReturn == null || isDeepSendable(t.typeReturn, leaves)),
		TypeKind.Struct when (isStructType(t)) => {
			for (const ft of t.typeChildren) {
				if (!isDeepSendable(ft, leaves)) return false;
			}
			return true;
		},
		TypeKind.Tuple => {
			for (const et of t.typeChildren) {
				if (!isDeepSendable(et, leaves)) return false;
			}
			return true;
		},
		TypeKind.GenericInstance => {
			if (t.typeReturn != null && !isDeepSendable(t.typeReturn, leaves)) return false;
			for (const ta of t.typeChildren) {
				if (!isDeepSendable(ta, leaves)) return false;
			}
			return true;
		},
		_ => false,
	};
}

// Type-level check: is the type safe to send (no mutable refs anywhere)?
// Follows reference isolation check: containsDangerousRefAux — recurse into structure.
// A string is copied at the boundary and an array's ownership travels with the
// message, so both are sendable.
function isTypeSendable(t: Type | null): boolean {
	return isDeepSendable(t, (SendLeaf.String | SendLeaf.Array) as int32);
}

// Arc<T> pointee rule (PARALOCK Amendment I): SHARE aliases the pointee across
// threads, so the pointee must be deep-immutable data — primitives, strings,
// and structs/tuples of those, recursively. This is STRICTER than
// isTypeSendable: an array is fine as a moved message argument (ownership
// transfers with it) but stays mutable through an Arc handle, so any array
// anywhere inside the pointee is rejected; so is any Ref (locks included).
export function isArcPointeeSendable(t: Type | null): boolean {
	return isDeepSendable(t, SendLeaf.String as int32);
}

export function checkArcPointeeSendable(ctx: CheckerContext, pointee: Type, line: int32, column: int32): void {
	if (isArcPointeeSendable(pointee)) return;
	addError(ctx, `Arc<T> pointee must be deep-immutable data — '${typeDisplayName(pointee)}' contains a reference or array\nSHARE aliases the pointee across threads; shared mutable state is Locked<T> (PARALOCK Amendment I)`,
		line, column);
}

// Locked<T> payload rule (PARALOCK I22). The payload lives INSIDE the cell and
// is written by a raw store under the lock, so it must own nothing: a store
// over an owning payload would have to destroy the previous value and take the
// incoming one, and the egress copy out of `read`/`update` would alias it.
// Deep-POD only — primitives and structs/tuples of primitives, recursively.
// A GenericParam is unknowable here; the concrete instantiation is re-checked
// after monomorphization.
export function isLockedPayloadSendable(t: Type | null): boolean {
	return isDeepSendable(t, SendLeaf.GenericParam as int32);
}

export function checkLockedPayloadSendable(ctx: CheckerContext, payload: Type, line: int32, column: int32): void {
	if (isLockedPayloadSendable(payload)) return;
	addError(ctx, `Locked<T> payload must be plain data — '${typeDisplayName(payload)}' owns memory (string, array or reference)\nthe cell's payload is stored under the lock by value; an owning payload has no destroy-on-store (PARALOCK I22)`,
		line, column);
}

// Call-site check: combines type analysis with expression-level rules (move, const binding).
// sendClass: true when the sender cannot park on a reply (void method or discarded
// result) — a plain const ref is a BORROW and needs the park, so it is rejected.
function isSendable(t: Type, argNode: Node, sendClass: boolean): boolean {
	if (t == null) return true;
	// move always transfers ownership safely
	if (argNode != null && argNode.kind == NodeKind.MoveExpr) return true;
	// If the type itself contains no refs, it's always sendable (value copy)
	if (isTypeSendable(t)) return true;
	if (t.kind == TypeKind.Ref) {
		// SHARE — Arc<T> only: atomic rc at the actor boundary makes the binding's
		// mutability irrelevant (rebinding the handle never writes the pointee).
		if (isAtomicRef(t)) return true;
		// BORROW — a const plain ref stays alive only while the sender parks on
		// the reply, so it is confined to awaited CALL invocations.
		if (!sendClass && argNode != null && argNode.resolvedSym != null
			&& !hasFlag(argNode.resolvedSym, SymbolFlag.Mutable)) return true;
		return false;
	}
	return false;
}

// Returns true when this arg is a plain-ref BORROW the caller must not discard
// (the discard itself is diagnosed at the call site via ctx.stmtPosExpr).
export function checkActorArgSendable(ctx: CheckerContext, argNode: Node, pi: number, sendClass: boolean): boolean {
	const t = argNode.nodeType;
	if (t == null) return false;
	const isPlainRefBorrow = !sendClass && t.kind == TypeKind.Ref && !isAtomicRef(t)
		&& argNode.kind != NodeKind.MoveExpr;
	if (isSendable(t, argNode, sendClass)) return isPlainRefBorrow;
	const argLabel = argNode.kind == NodeKind.Identifier
		? "'" + (argNode.data as IdentifierData).name + "'"
		: `arg ${pi}`;
	const typedesc = typeDisplayName(t);
	if (sendClass && t.kind == TypeKind.Ref) {
		addError(ctx, `fire-and-forget actor call would share a plain reference across threads\n${typedesc} ${argLabel} — use \`move\`, an \`Arc<T>\` argument, or await the reply (PARALOCK I21)`,
			argNode.location.line, argNode.location.column);
		return false;
	}
	const hint = match (t.kind) {
		TypeKind.Ref => {
			const varName = argNode.kind == NodeKind.Identifier ? " " + (argNode.data as IdentifierData).name : "";
			return ` — use \`move${varName}\` to transfer ownership`;
		},
		TypeKind.Function => " — closures may capture mutable state",
		_ => "",
	};
	addError(ctx, `actor methods only accept value types, \`move\`, or \`const\` references\n${typedesc} ${argLabel} is a mutable reference${hint}`,
		argNode.location.line, argNode.location.column);
	return false;
}

// A spawn thunk BORROWS the enclosing env (the lifted closure is handed
// `_env_main_` itself, not a copy), so a captured mutable binding is one memory
// cell shared with the parent thread — a read races a later parent write, and a
// write from the worker lands in the parent's slot. Only a closure created
// inside a loop body gets a per-iteration env copy, which is why a `for (let i…)`
// capture is a snapshot and everything else is not.
// The walk must therefore reach EVERY read position, so it delegates to
// forEachChild: the earlier hand-written arm list covered 4 shapes and silently
// let `x++` (UpdateExpr) and any argument wrapped in HiddenStdConv through.
function walkForMutableCaptures(node: Node | null, params: string[], reported: string[], ctx: CheckerContext): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.ArrowFunction) return;
	match (node.kind) {
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			let skip = false;
			for (const p of params) { if (p == d.name) skip = true; }
			for (const r of reported) { if (r == d.name) skip = true; }
			if (!skip) {
				// The lookup is by NAME against the scope of the spawn call site —
				// the thunk's own scopes are already popped by the time this runs.
				// A local declared inside the thunk that shadows an outer mutable
				// would resolve to the outer symbol here, so require the identifier
				// to actually point at it (resolvedSym is set by the body check that
				// ran just before; fall back to the name match when it is absent).
				const sym = lookupSymbol(ctx.table, d.name);
				const shadowed = node.resolvedSym != null && node.resolvedSym != sym;
				if (!shadowed && sym != null && hasFlag(sym, SymbolFlag.Mutable)) {
					addError(ctx, "mutable variable '" + d.name + "' cannot be captured by spawn — use const or move", node.location.line, node.location.column);
					reported.push(d.name);
				}
			}
		},
		// Binding positions: the identifiers under a pattern DECLARE names, they
		// do not read the enclosing scope. Walking them would look the name up
		// outside the thunk and misreport a same-named mutable as captured.
		NodeKind.ArrayPattern | NodeKind.ObjectPattern | NodeKind.ObjectPatternProp => {},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			walkForMutableCaptures(d.caseGuard, params, reported, ctx);
			walkForMutableCaptures(d.caseBody, params, reported, ctx);
		},
		_ => { forEachChild(node, (child: Node): void => { walkForMutableCaptures(child, params, reported, ctx); }); },
	};
}

export function checkSpawnCaptures(ctx: CheckerContext, closureNode: Node, spawnNode: Node): void {
	if (closureNode == null) return;
	let closure = closureNode;
	if (closure.kind == NodeKind.CallExpr) {
		const iifeCallee = (closure.data as CallExprData).callee;
		if (iifeCallee.kind == NodeKind.ArrowFunction) closure = (iifeCallee.data as ArrowFunctionData).arrowBody;
	}
	let params: string[] = [];
	let body: Node | null = null;
	if (closure.kind == NodeKind.ArrowFunction) {
		const ad = closure.data as ArrowFunctionData;
		params = ad.arrowParams;
		body = ad.arrowBody;
	} else if (closure.kind == NodeKind.FunctionExpr) {
		const fd = closure.data as FunctionExprData;
		params = fd.funcExprParams;
		body = fd.funcExprBody;
	}
	const reported: string[] = [];
	if (body != null) {
		walkForMutableCaptures(body, params, reported, ctx);
		if (ctx.currentActorName != "") {
			const actorReported: string[] = [];
			walkActorSpawnRules(ctx, body, actorReported);
		}
	}
}

// The checker wraps ref-typed reads in HiddenDeref/HiddenStdConv during body
// check (which runs before this walk) — `this.n` in read position arrives as
// MemberExpr(HiddenDeref(this), n). Assignment LHS stays unwrapped
// (leftPartOfAsgn). All shape tests must peel, or wrapped `this` reads
// misclassify as bare-this captures.
export function peelHidden(n: Node): Node {
	let cur = n;
	while (cur != null) {
		if (cur.kind == NodeKind.HiddenDeref) { cur = (cur.data as HiddenDerefData).expr; continue; }
		if (cur.kind == NodeKind.HiddenStdConv) { cur = (cur.data as HiddenStdConvData).convExpr; continue; }
		break;
	}
	return cur;
}

function isThisIdent(n: Node): boolean {
	const p = peelHidden(n);
	if (p == null) return false;
	if (p.kind != NodeKind.Identifier) return false;
	return (p.data as IdentifierData).name == "this";
}

function pushIfNew(list: string[], key: string): boolean {
	for (const k of list) { if (k == key) return false; }
	list.push(key);
	return true;
}

function actorDeclaresMethod(ctx: CheckerContext, methodName: string): boolean {
	const actorSym = lookupSymbol(ctx.table, ctx.currentActorName);
	if (actorSym == null || actorSym.declNode == null) return false;
	if (actorSym.declNode.kind != NodeKind.ActorDecl) return false;
	const body = (actorSym.declNode.data as ActorDeclData).actorBody;
	for (const m of body) {
		let mm = m;
		if (mm.kind == NodeKind.DecoratedDecl) {
			const dd = mm.data as DecoratedDeclData;
			if (dd.decoratedNode != null) mm = dd.decoratedNode;
		}
		if (mm.kind == NodeKind.MethodDecl && (mm.data as MethodDeclData).methodName == methodName) return true;
	}
	return false;
}

function walkActorSpawnRules(ctx: CheckerContext, node: Node, reportedKeys: string[]): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			walkActorSpawnRules(ctx, d.left, reportedKeys);
			walkActorSpawnRules(ctx, d.right, reportedKeys);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			walkActorSpawnRules(ctx, d.updateArg, reportedKeys);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			walkActorSpawnRules(ctx, d.moveArg, reportedKeys);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			walkActorSpawnRules(ctx, d.outArg, reportedKeys);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			if (isThisIdent(d.object)) {
				if (actorDeclaresMethod(ctx, d.property) && pushIfNew(reportedKeys, "m:" + d.property)) {
					addError(ctx, "spawn thunk cannot use method '" + d.property + "' of 'this' — the actor is suspended while spawn children run (PARALOCK S1/E61)", node.location.line, node.location.column);
				}
				return;
			}
			walkActorSpawnRules(ctx, d.object, reportedKeys);
		},
		NodeKind.Identifier => {
			if ((node.data as IdentifierData).name == "this" && pushIfNew(reportedKeys, "this")) {
				addError(ctx, "spawn thunk inside an actor method cannot capture 'this' — borrow individual fields instead (PARALOCK S1/E61)", node.location.line, node.location.column);
			}
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			const nestedSpawn = node.resolvedSym != null && node.resolvedSym.builtinKind == "PromiseSpawn";
			walkActorSpawnRules(ctx, d.callee, reportedKeys);
			let ai = 0;
			for (const arg of d.arguments) {
				if (!(nestedSpawn && ai == 0)) { walkActorSpawnRules(ctx, arg, reportedKeys); }
				ai = ai + 1;
			}
		},
		_ => { forEachChild(node, (child: Node): void => { walkActorSpawnRules(ctx, child, reportedKeys); }); },
	};
}

// ===== Tests =====
// The three boundary rules share one walk, so the leaf table IS the difference
// between them. Pin each admitted/refused leaf: a widened leaf would silently
// let one rule accept what only another may.

test "Arc pointee takes strings but never arrays" {
	assert isArcPointeeSendable(createStruct("PodS", ["s", "n"], [stringType(), int32Type()], true));
	assert !isArcPointeeSendable(createStruct("WithArr", ["a"], [createArray(int32Type())], true));
}

test "Arc pointee rejects a nested reference" {
	const inner = createStruct("Inner", ["n"], [int32Type()], true);
	assert !isArcPointeeSendable(createStruct("Holder", ["r"], [createRef(inner)], true));
}

test "Locked payload is deep-POD — owns nothing" {
	assert isLockedPayloadSendable(createStruct("Pod", ["n"], [int32Type()], true));
	assert !isLockedPayloadSendable(stringType());
	assert !isLockedPayloadSendable(createStruct("Owner", ["s"], [stringType()], true));
	assert !isLockedPayloadSendable(createArray(int32Type()));
}

test "a generic param passes the Locked payload rule, not the Arc pointee rule" {
	// Unknowable before instantiation: the Locked cell re-checks the concrete
	// payload there, while an Arc pointee has no such second look.
	assert isLockedPayloadSendable(createGenericParam("T"));
	assert !isArcPointeeSendable(createGenericParam("T"));
}


const SOLE_OWNER_TAG = " (PARALOCK E148)";

interface OwnerWalk {
	ctx: CheckerContext;
	sym: Symbol;
	name: string;
	moveNames: string[];
	thunk: Node;
	site: SourceLocation;
	at: SourceLocation;
	declared: boolean;
	reported: boolean;
}

function enclosingBody(ctx: CheckerContext): Node | null {
	const fn = ctx.currentFunction;
	if (fn == null || fn.declNode == null) return null;
	let dn = fn.declNode;
	if (dn.kind == NodeKind.DecoratedDecl) {
		const inner = (dn.data as DecoratedDeclData).decoratedNode;
		if (inner == null) return null;
		dn = inner;
	}
	if (dn.kind == NodeKind.FunctionDecl) return (dn.data as FunctionDeclData).fnBody;
	if (dn.kind == NodeKind.MethodDecl) return (dn.data as MethodDeclData).methodBody;
	if (dn.kind == NodeKind.ConstructorDecl) return (dn.data as ConstructorDeclData).ctorBody;
	if (dn.kind == NodeKind.ArrowFunction) return (dn.data as ArrowFunctionData).arrowBody;
	if (dn.kind == NodeKind.FunctionExpr) return (dn.data as FunctionExprData).funcExprBody;
	if (dn.kind == NodeKind.TestDecl) return (dn.data as TestDeclData).testBody;
	return null;
}

function peelView(n: Node): Node {
	let cur = peelHidden(n);
	while (cur != null) {
		if (cur.kind == NodeKind.TypeAssertion) { cur = peelHidden((cur.data as TypeAssertionData).asExpr); continue; }
		if (cur.kind == NodeKind.HiddenSubConv) { cur = peelHidden((cur.data as HiddenStdConvData).convExpr); continue; }
		break;
	}
	return cur;
}

function refersToOwner(n: Node, w: OwnerWalk): boolean {
	const p = peelView(n);
	if (p == null || p.kind != NodeKind.Identifier) return false;
	if ((p.data as IdentifierData).name != w.name) return false;
	return p.resolvedSym == null || p.resolvedSym == w.sym;
}

function rootedAtOwner(n: Node, w: OwnerWalk): boolean {
	let cur = peelView(n);
	while (cur != null) {
		if (cur.kind == NodeKind.MemberExpr) { cur = peelView((cur.data as MemberExprData).object); continue; }
		if (cur.kind == NodeKind.ArrayAccess) { cur = peelView((cur.data as ArrayAccessData).array); continue; }
		if (cur.kind == NodeKind.CallExpr) {
			const callee = peelView((cur.data as CallExprData).callee);
			if (callee == null || callee.kind != NodeKind.MemberExpr) return false;
			cur = peelView((callee.data as MemberExprData).object);
			continue;
		}
		break;
	}
	return cur != null && refersToOwner(cur, w);
}

function escapesOwner(n: Node | null, w: OwnerWalk): boolean {
	if (n == null) return false;
	const p = peelView(n);
	if (p == null) return false;
	if (p.kind == NodeKind.ConditionalExpr) {
		const d = p.data as ConditionalExprData;
		return escapesOwner(d.ternaryConsequent, w) || escapesOwner(d.ternaryAlternate, w);
	}
	if (p.kind == NodeKind.MatchExpr) {
		for (const c of (p.data as MatchExprData).matchCases) {
			if (escapesOwner((c.data as MatchCaseData).caseBody, w)) return true;
		}
		return false;
	}
	if (!rootedAtOwner(p, w)) return false;
	return p.nodeType == null || typeCarriesRef(p.nodeType);
}

function isMovedName(name: string, w: OwnerWalk): boolean {
	for (const m of w.moveNames) { if (m == name) return true; }
	return false;
}

function rootName(n: Node): string {
	const p = peelView(n);
	if (p == null) return "";
	if (p.kind == NodeKind.Identifier) return (p.data as IdentifierData).name;
	if (p.kind == NodeKind.MemberExpr) return rootName((p.data as MemberExprData).object);
	if (p.kind == NodeKind.ArrayAccess) return rootName((p.data as ArrayAccessData).array);
	return "";
}

function locBefore(a: SourceLocation, b: SourceLocation): boolean {
	return a.line < b.line || (a.line == b.line && a.column < b.column);
}

function describeExpr(n: Node): string {
	const p = peelView(n);
	if (p == null) return "an expression";
	if (p.kind == NodeKind.Identifier) return (p.data as IdentifierData).name;
	if (p.kind == NodeKind.MemberExpr) {
		const d = p.data as MemberExprData;
		return describeExpr(d.object) + "." + d.property;
	}
	if (p.kind == NodeKind.ArrayAccess) return describeExpr((p.data as ArrayAccessData).array) + "[]";
	return "an expression";
}

function reportNotSoleOwner(w: OwnerWalk, why: string): void {
	if (w.reported) return;
	w.reported = true;
	addError(w.ctx, "cannot move '" + w.name + "': it is not the sole owner — " + why + "; only a binding nothing else can reach may cross into the thunk" + SOLE_OWNER_TAG, w.at.line, w.at.column);
}

function reportEscape(n: Node, how: string, w: OwnerWalk): void {
	if (!locBefore(n.location, w.site)) return;
	reportNotSoleOwner(w, how + " at " + n.location.line + ":" + n.location.column);
}

function requireFresh(rhs: Node | null, what: string, w: OwnerWalk): void {
	if (rhs == null || w.reported || isFreshValue(rhs, w)) return;
	reportNotSoleOwner(w, what + " at " + rhs.location.line + ":" + rhs.location.column + " is not a fresh value (a literal, `new`, `move`, or a call whose receiver and arguments are fresh)");
}

function isFreshValue(n: Node | null, w: OwnerWalk): boolean {
	if (n == null) return true;
	if (n.nodeType != null && !typeCarriesRef(n.nodeType)) return true;
	const p = peelView(n);
	if (p == null) return true;
	if (p != n) return isFreshValue(p, w);
	return match (p.kind) {
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral
			| NodeKind.BigIntLiteral | NodeKind.RegexLiteral | NodeKind.MoveExpr | NodeKind.UnaryExpr
			| NodeKind.UpdateExpr | NodeKind.SizeofExpr => true,
		NodeKind.Identifier => {
			const name = (p.data as IdentifierData).name;
			for (const m of w.moveNames) { if (m == name) return true; }
			const sym = p.resolvedSym != null ? p.resolvedSym : lookupSymbol(w.ctx.table, name);
			if (sym == null) return true;
			if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Temp && sym.symbolKind != SymbolKind.Parameter) return true;
			return !typeCarriesRef(sym.symbolType);
		},
		NodeKind.ObjectLiteral => {
			for (const v of (p.data as ObjectLiteralData).properties) { if (!isFreshValue(v, w)) return false; }
			return true;
		},
		NodeKind.ArrayLiteral => {
			for (const e of (p.data as ArrayLiteralData).elements) { if (!isFreshValue(e, w)) return false; }
			return true;
		},
		NodeKind.SpreadExpr => isFreshValue((p.data as SpreadExprData).spreadArg, w),
		NodeKind.NewExpr => {
			for (const a of (p.data as NewExprData).newArguments) { if (!isFreshValue(a, w)) return false; }
			return true;
		},
		NodeKind.CallExpr => {
			const d = p.data as CallExprData;
			const callee = peelView(d.callee);
			if (callee != null && callee.kind == NodeKind.MemberExpr && !isFreshValue((callee.data as MemberExprData).object, w)) return false;
			for (const a of d.arguments) { if (!isFreshValue(a, w)) return false; }
			return true;
		},
		NodeKind.AwaitExpr => isFreshValue((p.data as AwaitExprData).awaitArg, w),
		NodeKind.ConditionalExpr => {
			const d = p.data as ConditionalExprData;
			return isFreshValue(d.ternaryConsequent, w) && isFreshValue(d.ternaryAlternate, w);
		},
		NodeKind.MatchExpr => {
			for (const c of (p.data as MatchExprData).matchCases) {
				const b = (c.data as MatchCaseData).caseBody;
				if (b.kind == NodeKind.BlockStmt || !isFreshValue(b, w)) return false;
			}
			return true;
		},
		NodeKind.TryExpr => {
			const d = p.data as TryExprData;
			return isFreshValue(d.tryArg, w) && (!d.hasCatch || isFreshValue(d.catchVal, w));
		},
		NodeKind.BinaryExpr => {
			const d = p.data as BinaryExprData;
			if (d.operator == "??" || d.operator == "||" || d.operator == "&&") return isFreshValue(d.left, w) && isFreshValue(d.right, w);
			return true;
		},
		_ => false,
	};
}

function capturesOwner(node: Node | null, w: OwnerWalk): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.Identifier) return refersToOwner(node, w);
	if (node.kind == NodeKind.ArrayPattern || node.kind == NodeKind.ObjectPattern || node.kind == NodeKind.ObjectPatternProp) return false;
	if (node.kind == NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		return capturesOwner(d.caseGuard, w) || capturesOwner(d.caseBody, w);
	}
	const hit: boolean[] = [false];
	forEachChild(node, (child: Node): void => { if (!hit[0] && capturesOwner(child, w)) hit[0] = true; });
	return hit[0];
}

function walkOwner(node: Node | null, w: OwnerWalk): void {
	if (node == null || w.reported || node == w.thunk) return;
	match (node.kind) {
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (node == w.sym.declNode) {
				w.declared = true;
				requireFresh(d.initializer, "the value bound to '" + w.name + "'", w);
			} else if (!isMovedName(d.declName, w) && escapesOwner(d.initializer, w)) {
				reportEscape(node, "it is bound to '" + d.declName + "'", w);
			}
			walkOwner(d.initializer, w);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			if (escapesOwner(d.destrInit, w)) reportEscape(node, "it is destructured", w);
			walkOwner(d.destrInit, w);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			if (d.forOfBinding == w.name && node.resolvedSym == w.sym) {
				w.declared = true;
				reportNotSoleOwner(w, "for..of binds it to an element of '" + describeExpr(d.forOfIterable) + "', which still holds it");
			}
			walkOwner(d.forOfIterable, w);
			walkOwner(d.forOfBody, w);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator == "=") {
				if (rootedAtOwner(d.left, w)) requireFresh(d.right, "the value assigned into '" + describeExpr(d.left) + "'", w);
				else if (!isMovedName(rootName(d.left), w) && escapesOwner(d.right, w)) reportEscape(node, "it is assigned to '" + describeExpr(d.left) + "'", w);
			}
			walkOwner(d.left, w);
			walkOwner(d.right, w);
		},
		NodeKind.ObjectLiteral => {
			for (const v of (node.data as ObjectLiteralData).properties) {
				if (escapesOwner(v, w)) reportEscape(v, "it is stored in an object literal", w);
				walkOwner(v, w);
			}
		},
		NodeKind.ArrayLiteral => {
			for (const e of (node.data as ArrayLiteralData).elements) {
				if (escapesOwner(e, w)) reportEscape(e, "it is stored in an array literal", w);
				walkOwner(e, w);
			}
		},
		NodeKind.SpreadExpr => {
			const a = (node.data as SpreadExprData).spreadArg;
			if (escapesOwner(a, w)) reportEscape(a, "it is spread", w);
			walkOwner(a, w);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			const callee = peelView(d.callee);
			const ownerIsReceiver = callee != null && callee.kind == NodeKind.MemberExpr && rootedAtOwner((callee.data as MemberExprData).object, w);
			for (const a of d.arguments) {
				if (ownerIsReceiver) requireFresh(a, "the argument passed into '" + describeExpr(callee) + "'", w);
				else if (escapesOwner(a, w)) reportEscape(a, "it is passed to '" + describeExpr(callee) + "'", w);
			}
			walkOwner(d.callee, w);
			for (const a of d.arguments) walkOwner(a, w);
		},
		NodeKind.NewExpr => {
			for (const a of (node.data as NewExprData).newArguments) {
				if (escapesOwner(a, w)) reportEscape(a, "it is passed to a constructor", w);
				walkOwner(a, w);
			}
		},
		NodeKind.YieldExpr => {
			const a = (node.data as YieldExprData).yieldArg;
			if (escapesOwner(a, w)) reportEscape(a, "it is yielded", w);
			walkOwner(a, w);
		},
		NodeKind.OutExpr => {
			const a = (node.data as OutExprData).outArg;
			if (rootedAtOwner(a, w)) reportEscape(a, "it is passed as an out argument", w);
		},
		NodeKind.DeferStmt => {
			if (capturesOwner(node, w)) reportEscape(node, "a defer that runs after the move uses it", w);
		},
		NodeKind.ArrowFunction | NodeKind.FunctionExpr | NodeKind.FunctionDecl => {
			if (capturesOwner(node, w)) reportEscape(node, "a closure captures it", w);
		},
		NodeKind.ArrayPattern | NodeKind.ObjectPattern | NodeKind.ObjectPatternProp => {},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			walkOwner(d.caseGuard, w);
			walkOwner(d.caseBody, w);
		},
		_ => { forEachChild(node, (child: Node): void => { walkOwner(child, w); }); },
	};
}

export function checkMoveSoleOwner(ctx: CheckerContext, sym: Symbol, moveNames: string[], thunk: Node, at: SourceLocation): void {
	if (!typeCarriesRef(sym.symbolType)) return;
	if (sym.symbolKind == SymbolKind.Parameter) {
		addError(ctx, "cannot move '" + sym.name + "': it is a parameter, so the caller still owns it — bind a fresh value locally and move that" + SOLE_OWNER_TAG, at.line, at.column);
		return;
	}
	if (hasFlag(sym, SymbolFlag.Global)) {
		addError(ctx, "cannot move '" + sym.name + "': it is a module-level binding that every function in the module can reach — move a binding local to one function" + SOLE_OWNER_TAG, at.line, at.column);
		return;
	}
	const body = enclosingBody(ctx);
	const w: OwnerWalk = { ctx, sym, name: sym.name, moveNames, thunk, site: thunk.location, at, declared: false, reported: false };
	if (body != null) walkOwner(body, w);
	if (!w.declared && !w.reported) {
		addError(ctx, "cannot move '" + sym.name + "': it is declared outside the enclosing function, so that function cannot prove it is the sole owner" + SOLE_OWNER_TAG, at.line, at.column);
	}
}
