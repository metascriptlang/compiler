// Actor sendability + this-write isolation rules.

import { ActorDeclData, ArrayAccessData, ArrayLiteralData, ArrayPatternData, ArrowFunctionData, AwaitExprData, BinaryExprData, CallExprData, ConditionalExprData, ConstructorDeclData, DecoratedDeclData, DestructuringDeclData, ForOfStmtData, FunctionDeclData, FunctionExprData, HiddenDerefData, HiddenStdConvData, IdentifierData, MacroInvocationData, MatchCaseData, MatchExprData, MemberExprData, MethodDeclData, MoveExprData, NewExprData, Node, NodeFlag, NodeKind, ObjectLiteralData, ObjectPatternData, ObjectPatternPropData, OutExprData, PropertyDeclData, ReturnStmtData, SourceLocation, SpreadExprData, Symbol, SymbolKind, TestDeclData, ThrowStmtData, Type, TypeKind, UpdateExprData, VariableDeclData, YieldExprData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError, addWarning, dispatchEntryFor, dispatchOverridesFor, isGenericFn, isOutsideResolvedStd } from "./context";
import { isAsyncFunctionNode } from "./freestanding";
import { Effect, EffectCause, FreshScope, aliasTarget, boundRoutine, callEffect, deferEffectCheck, isFreshValue, newEffect, peelView, routineEffect, walkEffect, walkWithViews } from "./effects";
import { constBindingInitializer } from "./constFold";
import { ScopeKind, SymbolFlag, hasFlag, lookupSymbol, scopeHolding } from "./symbol";
import { PEEL_ALIAS, createArray, createGenericParam, createRef, createStruct, int32Type, isAwaitable, isPrimitiveKind, peelThrough, isSendableFunction, isStructType, isAtomicRef, isNumeric, isReadonlyView, stringType, typeCarriesRef, typeDisplayName } from "./types";

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
	Function = 8,      // only a Sendable<F>, whose source was checked where it converted
}

function isDeepSendable(t: Type | null, leaves: int32, declaresHook: (owner: Type) => boolean): boolean {
	if (t == null) return true;
	if (isPrimitiveKind(t.kind)) return true;
	return match (t.kind) {
		TypeKind.String => (leaves & SendLeaf.String) != 0,
		TypeKind.GenericParam => (leaves & SendLeaf.GenericParam) != 0,
		TypeKind.Function => (leaves & SendLeaf.Function) != 0 && isSendableFunction(t),
		TypeKind.Array => (leaves & SendLeaf.Array) != 0
			&& (t.typeReturn == null || isDeepSendable(t.typeReturn, leaves, declaresHook)),
		TypeKind.Struct when (isStructType(t)) => {
			if (declaresHook(t)) return false;
			for (const ft of t.typeChildren) {
				if (!isDeepSendable(ft, leaves, declaresHook)) return false;
			}
			return true;
		},
		TypeKind.Tuple => {
			for (const et of t.typeChildren) {
				if (!isDeepSendable(et, leaves, declaresHook)) return false;
			}
			return true;
		},
		TypeKind.GenericInstance => {
			if (declaresHook(t)) return false;
			if (t.typeReturn != null && !isDeepSendable(t.typeReturn, leaves, declaresHook)) return false;
			for (const ta of t.typeChildren) {
				if (!isDeepSendable(ta, leaves, declaresHook)) return false;
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
	return isDeepSendable(t, (SendLeaf.String | SendLeaf.Array | SendLeaf.Function) as int32, declaresNoHook);
}

function declaresNoHook(owner: Type): boolean {
	return false;
}

function hookedPayloadError(ctx: CheckerContext, what: string, t: Type, line: int32, column: int32): void {
	addError(ctx, `${what} must not declare a lifecycle hook — '${typeDisplayName(t)}' declares one or holds a value that does\nthe cell copies its payload in and out without running onCopy, so onDestroy would run once per copy`,
		line, column);
}

// Arc<T> pointee rule (PARALOCK Amendment I): SHARE aliases the pointee across
// threads, so the pointee must be deep-immutable data — primitives, strings,
// and structs/tuples of those, recursively. This is STRICTER than
// isTypeSendable: an array is fine as a moved message argument (ownership
// transfers with it) but stays mutable through an Arc handle, so any array
// anywhere inside the pointee is rejected; so is any Ref (locks included).
export function isArcPointeeSendable(t: Type | null): boolean {
	return isDeepSendable(t, SendLeaf.String as int32, declaresNoHook);
}

export function checkActorStaticField(ctx: CheckerContext, raw: Node): void {
	let member = raw;
	if (member.kind == NodeKind.DecoratedDecl) member = (member.data as DecoratedDeclData).decoratedNode;
	if (member == null || member.kind != NodeKind.PropertyDecl) return;
	const pd = member.data as PropertyDeclData;
	if (!pd.propIsStatic) return;
	if (!pd.propIsReadonly) {
		addError(ctx, `an actor's static '${pd.propName}' is shared by every instance across threads, so it must be 'static readonly' — keep mutable state in an instance field, or share it through 'static readonly ${pd.propName} = new Locked<T>(…)' (PARALOCK I22)`,
			member.location.line, member.location.column);
		return;
	}
	let t = member.nodeType;
	if ((t == null || t.kind == TypeKind.Inferred) && pd.propInitializer != null) t = pd.propInitializer.nodeType;
	if (t == null || t.kind == TypeKind.Inferred || t.kind == TypeKind.Error) return;
	if (isArcPointeeSendable(t) || isAtomicRef(t)) return;
	addError(ctx, `'${typeDisplayName(t)}' can still be mutated through the readonly static '${pd.propName}', and its refcount is not atomic — an actor's static must be plain data, Arc<T> or Locked<T> (PARALOCK I22)`,
		member.location.line, member.location.column);
}

function isNonisolatedValueType(t: Type): boolean {
	return isNumeric(t) || match (t.kind) {
		TypeKind.BigInt | TypeKind.Boolean | TypeKind.BooleanLiteral | TypeKind.NumberLiteral
			| TypeKind.Enum | TypeKind.EnumLiteral | TypeKind.String | TypeKind.StringLiteral => true,
		_ => false,
	};
}

export function checkActorNonisolatedField(ctx: CheckerContext, actorSym: Symbol, raw: Node): void {
	let member = raw;
	if (member.kind == NodeKind.DecoratedDecl) member = (member.data as DecoratedDeclData).decoratedNode;
	if (member == null || member.kind != NodeKind.PropertyDecl) return;
	const pd = member.data as PropertyDeclData;
	if (pd.propIsStatic || !hasNonisolatedField(actorSym, pd.propName)) return;
	let t = member.nodeType;
	if ((t == null || t.kind == TypeKind.Inferred) && pd.propInitializer != null) t = pd.propInitializer.nodeType;
	if (t != null && t.kind == TypeKind.Error) return;
	if (pd.propIsReadonly && t != null && isNonisolatedValueType(t)) return;
	addError(ctx, "a nonisolated field is read from other threads, so it must be readonly and of a value type (number, bigint, boolean, string, enum)",
		member.location.line, member.location.column);
}

function crossesAsReply(t: Type | null): boolean {
	if (t == null || !typeCarriesRef(t) || isAtomicRef(t)) return true;
	if (isDeepSendable(t, (SendLeaf.String | SendLeaf.Function) as int32, declaresNoHook)) return true;
	if (t.kind == TypeKind.GenericInstance && t.typeExtra != null && t.typeExtra!.kind == TypeKind.Union) {
		for (const a of t.typeChildren) {
			if (!crossesAsReply(a)) return false;
		}
		return true;
	}
	if (t.kind == TypeKind.Ref) return t.sym != null && t.sym.symbolKind == SymbolKind.Actor;
	if (t.kind != TypeKind.Union) return false;
	for (const c of t.typeChildren) {
		if (!crossesAsReply(c)) return false;
	}
	return true;
}

const REPLY_SCOPE: FreshScope = {
	moveNames: [],
	table: null,
	buildsAlone: (site: Node): boolean => (site.kind == NodeKind.NewExpr ? newEffect(site, Effect.SideEffect) : callEffect(site, Effect.SideEffect)) == null,
};

function sharedReplyPart(ctx: CheckerContext, n: Node | null, result: Node, method: string): Node | null {
	if (n == null) return null;
	const p = peelView(n);
	if (crossesAsReply(p.nodeType)) return null;
	return match (p.kind) {
		NodeKind.ArrayLiteral => firstSharedReplyPart(ctx, (p.data as ArrayLiteralData).elements, result, method),
		NodeKind.ObjectLiteral => firstSharedReplyPart(ctx, (p.data as ObjectLiteralData).properties, result, method),
		NodeKind.SpreadExpr => {
			const arg = (p.data as SpreadExprData).spreadArg;
			const t = arg.nodeType != null ? peelThrough(arg.nodeType!, PEEL_ALIAS) : null;
			if (t != null && t.kind == TypeKind.Array && crossesAsReply(t.typeReturn)) return null;
			return sharedReplyPart(ctx, arg, result, method);
		},
		NodeKind.ConditionalExpr => {
			const d = p.data as ConditionalExprData;
			const a = sharedReplyPart(ctx, d.ternaryConsequent, result, method);
			return a != null ? a : sharedReplyPart(ctx, d.ternaryAlternate, result, method);
		},
		NodeKind.Identifier when (p.resolvedSym != null && p.resolvedSym!.name != "this") => {
			checkReplyBindingSoleOwner(ctx, p.resolvedSym!, result, p.location, method);
			return null;
		},
		_ => isFreshValue(p, REPLY_SCOPE) ? null : p,
	};
}

function replyHead(method: string): string {
	return `the reply of '${method}' may cross to the caller while the actor still reaches it`;
}

const REPLY_CHOICE = "reply with a copy (a number, string or plain struct), a fresh value nothing in the actor keeps (a literal, `new`, or a local built for the reply), or an Arc<T>";

function rewordSoleOwnerAsReply(ctx: CheckerContext, name: string, method: string, at: SourceLocation): void {
	const prefix = "cannot move '" + name + "': ";
	for (let i = 0; i < ctx.errors.length; i += 1) {
		const m = ctx.errors[i].message;
		if (ctx.errors[i].line != at.line || ctx.errors[i].column != at.column || !m.startsWith(prefix) || !m.endsWith(SOLE_OWNER_TAG)) continue;
		let why = m.substring(prefix.length, m.length - SOLE_OWNER_TAG.length);
		const tail = why.indexOf("; only a binding");
		if (tail >= 0) why = why.substring(0, tail);
		else {
			const advice = why.indexOf(" — ");
			if (advice >= 0) why = why.substring(0, advice);
		}
		ctx.errors[i].message = `${replyHead(method)} — '${name}' ${why.startsWith("it ") ? why.substring(3) : why}; ${REPLY_CHOICE}`;
	}
}

function checkReplyBindingSoleOwner(ctx: CheckerContext, sym: Symbol, result: Node, at: SourceLocation, method: string): void {
	checkMoveSoleOwner(ctx, sym, [], result, at);
	rewordSoleOwnerAsReply(ctx, sym.name, method, at);
	deferEffectCheck(result, "replyWording", (late: CheckerContext): void => rewordSoleOwnerAsReply(late, sym.name, method, at));
}

function firstSharedReplyPart(ctx: CheckerContext, nodes: Node[], result: Node, method: string): Node | null {
	for (const n of nodes) {
		const s = sharedReplyPart(ctx, n, result, method);
		if (s != null) return s;
	}
	return null;
}

export function checkActorReplies(ctx: CheckerContext, raw: Node): void {
	let member = raw;
	if (member.kind == NodeKind.DecoratedDecl) member = (member.data as DecoratedDeclData).decoratedNode;
	if (member == null || member.kind != NodeKind.MethodDecl || member.resolvedSym == null) return;
	const d = member.data as MethodDeclData;
	if (d.methodIsStatic || d.methodVisibility == "private" || d.methodName.startsWith("#") || d.methodBody == null) return;
	if (isGenericFn(d.methodFlags)) {
		addError(ctx, `actor method '${d.methodName}' is generic, so the reply of each instance cannot be checked before it crosses to the caller — write a concrete method for each type the caller needs, or keep the generic code in a module-level function that a concrete method calls`,
			member.location.line, member.location.column);
		return;
	}
	const results: Node[] = [];
	collectResults(d.methodBody, results);
	const here = ctx.currentFunction;
	ctx.currentFunction = member.resolvedSym;
	for (const r of results) {
		const shared = sharedReplyPart(ctx, r, r, d.methodName);
		if (shared == null) continue;
		const name = describeExpr(shared);
		addError(ctx, `${replyHead(d.methodName)} — it replies with ${name == "an expression" ? "a value" : "'" + name + "'"}, which stays in the actor; ${REPLY_CHOICE}`,
			shared.location.line, shared.location.column);
	}
	ctx.currentFunction = here;
}

export function checkArcPointeeSendable(ctx: CheckerContext, pointee: Type, declaresHook: (owner: Type) => boolean, line: int32, column: int32): void {
	if (isDeepSendable(pointee, SendLeaf.String as int32, declaresHook)) return;
	if (isArcPointeeSendable(pointee)) {
		hookedPayloadError(ctx, "Arc<T> pointee", pointee, line, column);
		return;
	}
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
	return isDeepSendable(t, SendLeaf.GenericParam as int32, declaresNoHook);
}

export function checkLockedPayloadSendable(ctx: CheckerContext, payload: Type, declaresHook: (owner: Type) => boolean, line: int32, column: int32): void {
	if (isDeepSendable(payload, SendLeaf.GenericParam as int32, declaresHook)) return;
	if (isLockedPayloadSendable(payload)) {
		hookedPayloadError(ctx, "Locked<T> payload", payload, line, column);
		return;
	}
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
export function checkActorArgSendable(ctx: CheckerContext, call: Node, argNode: Node, pi: number, sendClass: boolean): boolean {
	const t = argNode.nodeType;
	if (t == null) return false;
	const isPlainRefBorrow = !sendClass && t.kind == TypeKind.Ref && !isAtomicRef(t)
		&& argNode.kind != NodeKind.MoveExpr;
	if (t.kind != TypeKind.Function) {
		const path = plainFunctionPath(t, []);
		if (path != null) {
			const label = describeExpr(argNode);
			addError(ctx, `${label == "an expression" ? "the argument" : label}${path} is a plain function inside a value that crosses to the actor, so it may capture mutable state and would run on the actor's thread — declare that field Sendable<F>, so its closure is checked where it is built, or send the data without the function`,
				argNode.location.line, argNode.location.column);
			return false;
		}
	}
	if (sendClass) refuseSentClosures(ctx, argNode, argNode);
	if (isSendable(t, argNode, sendClass)) {
		if (isPlainRefBorrow && (t.sym == null || t.sym.symbolKind != SymbolKind.Actor)) refuseKeptBorrow(call, argNode, pi);
		return isPlainRefBorrow;
	}
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
		TypeKind.Function => " — closures may capture mutable state; take a Sendable<F> instead",
		_ => "",
	};
	addError(ctx, `actor methods only accept value types, \`move\`, or \`const\` references\n${typedesc} ${argLabel} is a mutable reference${hint}`,
		argNode.location.line, argNode.location.column);
	return false;
}

function plainFunctionPath(t: Type | null, seen: Type[]): string | null {
	if (t == null || seen.includes(t)) return null;
	if (t.kind == TypeKind.Function) return isSendableFunction(t) ? null : "";
	seen.push(t);
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Span) {
		const p = plainFunctionPath(t.typeReturn, seen);
		return p == null ? null : "[]" + p;
	}
	if (t.kind == TypeKind.Struct || t.kind == TypeKind.Tuple) {
		for (let i = 0; i < t.typeChildren.length; i += 1) {
			const p = plainFunctionPath(t.typeChildren[i], seen);
			if (p != null) return (i < t.typeNames.length ? "." + t.typeNames[i] : "[" + i + "]") + p;
		}
		return null;
	}
	if (t.kind == TypeKind.Union || t.kind == TypeKind.GenericInstance || t.kind == TypeKind.Varargs) {
		for (const c of t.typeChildren) {
			const p = plainFunctionPath(c, seen);
			if (p != null) return p;
		}
	}
	return plainFunctionPath(t.typeReturn, seen);
}

function refuseSentClosures(ctx: CheckerContext, argNode: Node, at: Node): void {
	const p = peelView(argNode);
	if (p.kind == NodeKind.MoveExpr) {
		const moved = peelView((p.data as MoveExprData).moveArg);
		const init = moved.kind == NodeKind.Identifier ? constBindingInitializer(moved.resolvedSym) : null;
		if (init != null) refuseSentClosures(ctx, init, at);
		return;
	}
	if (p.kind == NodeKind.ObjectLiteral || p.kind == NodeKind.ArrayLiteral) {
		const parts = p.kind == NodeKind.ObjectLiteral ? (p.data as ObjectLiteralData).properties : (p.data as ArrayLiteralData).elements;
		for (const e of parts) refuseSentClosures(ctx, e, at);
		return;
	}
	if (p.kind == NodeKind.ArrowFunction || p.kind == NodeKind.FunctionExpr || isSendableFunction(p.nodeType) || isSendableFunction(argNode.nodeType)) refuseSentClosureBorrow(ctx, argNode, at);
}

function refuseSentClosureBorrow(ctx: CheckerContext, argNode: Node, at: Node): void {
	let source = spawnedClosure(peelHidden(argNode));
	const sym = source.kind == NodeKind.Identifier ? aliasTarget(source.resolvedSym) : null;
	if (sym != null && sym.symbolKind == SymbolKind.Function) {
		if (isModuleScoped(ctx, sym) || sym.declNode == null) return;
		source = sym.declNode!;
	}
	const name = describeExpr(argNode);
	if (source.kind != NodeKind.ArrowFunction && source.kind != NodeKind.FunctionExpr && source.kind != NodeKind.FunctionDecl) {
		addError(ctx, `a send without a reply runs '${name}' on the actor after this code moves on, and its captures cannot be seen here — pass a closure literal or a function declaration whose captures are copies, Arc<T> or Locked<T>, or give the method a result and await it so the call lends what the function captures`,
			at.location.line, at.location.column);
		return;
	}
	const views: Symbol[] = [];
	const moved: Symbol[] = [];
	collectBorrowCaptures(ctx, source, views, moved);
	for (const v of views) {
		if (moved.includes(v)) continue;
		addError(ctx, `a send without a reply runs this closure on the actor after this code moves on, so it cannot borrow '${v.name}': no reply ends the loan — capture a copy instead (const n = ${v.name}.field, or a clone), share it through Arc<T> or Locked<T>, or give the method a result and await it so the call lends '${v.name}' until the reply`,
			at.location.line, at.location.column);
		return;
	}
}

function routineParts(sym: Symbol | null): Node | null {
	if (sym == null) return null;
	let dn = sym.declNode;
	if (dn != null && dn.kind == NodeKind.DecoratedDecl) dn = (dn.data as DecoratedDeclData).decoratedNode;
	return dn != null && (dn.kind == NodeKind.MethodDecl || dn.kind == NodeKind.FunctionDecl) ? dn : null;
}

function firstArgParam(dn: Node, call: Node): int32 {
	if (dn.paramSyms!.length > 0 && dn.paramSyms![0].name == "this") return 1;
	return call.flags.has(NodeFlag.ExtCall) && !call.flags.has(NodeFlag.ExtStatic) ? 1 : 0;
}

function routineBody(dn: Node): Node | null {
	return dn.kind == NodeKind.MethodDecl ? (dn.data as MethodDeclData).methodBody : (dn.data as FunctionDeclData).fnBody;
}

function rootOfPath(n: Node): Node | null {
	let cur = peelView(n);
	while (cur != null) {
		if (cur.kind == NodeKind.MemberExpr) { cur = peelView((cur.data as MemberExprData).object); continue; }
		if (cur.kind == NodeKind.ArrayAccess) { cur = peelView((cur.data as ArrayAccessData).array); continue; }
		if (cur.kind == NodeKind.CallExpr) {
			const callee = peelView((cur.data as CallExprData).callee);
			if (callee == null || callee.kind != NodeKind.MemberExpr) return cur;
			cur = peelView((callee.data as MemberExprData).object);
			continue;
		}
		break;
	}
	return cur;
}

// lent: the parameter and every local that still reaches it; held: locals that alias the
// actor's own state or module state, so a value stored through them outlives the call.
interface KeptWalk { lent: Symbol[]; held: Symbol[]; seen: Node[]; }

function outlivesCall(n: Node, w: KeptWalk): boolean {
	const root = rootOfPath(n);
	if (root == null || root.kind != NodeKind.Identifier) return false;
	if (isThisIdent(root)) return true;
	const sym = root.resolvedSym;
	return sym != null && (hasFlag(sym, SymbolFlag.Global) || w.held.includes(sym));
}

function capturesLent(node: Node, lent: Symbol[]): boolean {
	if (node.kind == NodeKind.Identifier) return node.resolvedSym != null && lent.includes(node.resolvedSym);
	const hit: boolean[] = [false];
	forEachChild(node, (child: Node): void => { if (!hit[0] && capturesLent(child, lent)) hit[0] = true; });
	return hit[0];
}

function reachesLent(n: Node | null, lent: Symbol[]): boolean {
	if (n == null) return false;
	const p = peelView(n);
	if (p == null) return false;
	if (p.kind == NodeKind.ArrowFunction || p.kind == NodeKind.FunctionExpr) return capturesLent(p, lent);
	if (p.kind == NodeKind.ConditionalExpr) {
		const d = p.data as ConditionalExprData;
		return reachesLent(d.ternaryConsequent, lent) || reachesLent(d.ternaryAlternate, lent);
	}
	if (p.kind == NodeKind.MatchExpr) {
		for (const c of (p.data as MatchExprData).matchCases) {
			if (reachesLent((c.data as MatchCaseData).caseBody, lent)) return true;
		}
		return false;
	}
	if (p.kind == NodeKind.ObjectLiteral) {
		for (const v of (p.data as ObjectLiteralData).properties) { if (reachesLent(v, lent)) return true; }
		return false;
	}
	if (p.kind == NodeKind.ArrayLiteral) {
		for (const e of (p.data as ArrayLiteralData).elements) { if (reachesLent(e, lent)) return true; }
		return false;
	}
	const root = rootOfPath(p);
	if (root != null && root.kind == NodeKind.CallExpr) return (p.nodeType == null || typeCarriesRef(p.nodeType)) && callReturnsLent(root, lent);
	if (root == null || root.kind != NodeKind.Identifier || root.resolvedSym == null || !lent.includes(root.resolvedSym)) return false;
	return p.nodeType == null || typeCarriesRef(p.nodeType);
}

const returnWalk: Node[] = [];

function callReturnsLent(call: Node, lent: Symbol[]): boolean {
	const d = call.data as CallExprData;
	const reached = d.arguments.map((a: Node): boolean => reachesLent(a, lent));
	if (!reached.includes(true)) return false;
	const callee = peelView(d.callee);
	const routine = routineParts(call.resolvedSym != null ? call.resolvedSym : (callee != null ? callee.resolvedSym : null));
	if (routine == null || routine.paramSyms == null) return true;
	if (returnWalk.includes(routine)) return false;
	const inner: Symbol[] = [];
	const first = firstArgParam(routine, call);
	for (let i = 0; i < reached.length && first + i < routine.paramSyms!.length; i += 1) {
		if (reached[i]) inner.push(routine.paramSyms![first + i]);
	}
	returnWalk.push(routine);
	const hit = returnsReach(routineBody(routine), inner);
	returnWalk.pop();
	return hit;
}

function returnsReach(node: Node | null, lent: Symbol[]): boolean {
	if (node == null || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr) return false;
	if (node.kind == NodeKind.VariableDecl) {
		const sym = node.resolvedSym;
		if (sym != null && reachesLent((node.data as VariableDeclData).initializer, lent)) lent.push(sym);
	} else if (node.kind == NodeKind.ReturnStmt) {
		if (reachesLent((node.data as ReturnStmtData).argument, lent)) return true;
	}
	const hit: boolean[] = [false];
	forEachChild(node, (child: Node): void => { if (!hit[0] && returnsReach(child, lent)) hit[0] = true; });
	return hit[0];
}

function findKeptSite(node: Node | null, w: KeptWalk): Node | null {
	if (node == null) return null;
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const sym = node.resolvedSym;
		if (sym != null && reachesLent(d.initializer, w.lent)) w.lent.push(sym);
		else if (sym != null && d.initializer != null && typeCarriesRef(sym.symbolType) && outlivesCall(d.initializer, w)) w.held.push(sym);
	} else if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator == "=" && outlivesCall(d.left, w) && reachesLent(d.right, w.lent)) return node;
	} else if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		const callee = peelView(d.callee);
		const recv = callee != null && callee.kind == NodeKind.MemberExpr ? (callee.data as MemberExprData).object : null;
		if (recv == null) {
			const routine = routineParts(node.resolvedSym != null ? node.resolvedSym : (callee != null ? callee.resolvedSym : null));
			if (routine != null && keptThrough(routine, node, w)) return node;
		} else if (!isThisIdent(recv) && outlivesCall(recv, w)) {
			for (const a of d.arguments) { if (reachesLent(a, w.lent)) return node; }
		}
	}
	const hit: (Node | null)[] = [null];
	forEachChild(node, (child: Node): void => { if (hit[0] == null) hit[0] = findKeptSite(child, w); });
	return hit[0];
}

function keptThrough(routine: Node, call: Node, w: KeptWalk): boolean {
	if (routine.paramSyms == null || w.seen.includes(routine)) return false;
	const args = (call.data as CallExprData).arguments;
	const inner: Symbol[] = [];
	const first = firstArgParam(routine, call);
	for (let i = 0; i < args.length && first + i < routine.paramSyms!.length; i += 1) {
		if (reachesLent(args[i], w.lent)) inner.push(routine.paramSyms![first + i]);
	}
	if (inner.length == 0) return false;
	w.seen.push(routine);
	return findKeptSite(routineBody(routine), { lent: inner, held: [], seen: w.seen }) != null;
}

// The receiving parameter of an awaited CALL is lent for the call only, so the
// actor must not keep it in its own state or in module state.
function refuseKeptBorrow(call: Node, argNode: Node, pi: number): void {
	const method = routineParts(call.resolvedSym);
	if (method == null || method.kind != NodeKind.MethodDecl) return;
	deferEffectCheck(argNode, "keptBorrow", (ctx: CheckerContext): void => {
		if (method.paramSyms == null || firstArgParam(method, call) + pi >= method.paramSyms!.length) return;
		const param = method.paramSyms![firstArgParam(method, call) + pi];
		const site = findKeptSite(routineBody(method), { lent: [param], held: [], seen: [method] });
		if (site == null) return;
		const what = site.kind == NodeKind.BinaryExpr
			? "stores it in '" + describeExpr((site.data as BinaryExprData).left) + "'"
			: "passes it to '" + describeExpr((site.data as CallExprData).callee) + "'";
		const arg = argNode.kind == NodeKind.Identifier ? (argNode.data as IdentifierData).name : "the argument";
		addError(ctx, `actor method '${(method.data as MethodDeclData).methodName}' keeps its parameter '${param.name}': it ${what} at ${site.location.line}:${site.location.column}, but '${arg}' is only lent for the awaited call\nsend ownership with \`move ${arg}\`, or copy the scalar fields it needs into the actor's state (PARALOCK I21)`,
			argNode.location.line, argNode.location.column);
	});
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
function walkForMutableCaptures(node: Node | null, params: string[], reported: string[], ctx: CheckerContext, by: string, via: Node[]): void {
	if (node == null) return;
	match (node.kind) {
		// A nested routine runs on the same thread as the thunk that calls it, so its
		// captures are the thunk's captures; its own parameters bind, like the thunk's.
		NodeKind.FunctionDecl | NodeKind.FunctionExpr | NodeKind.ArrowFunction => {
			const nested = routineParamsAndBody(node);
			walkForMutableCaptures(nested.body, params.concat(nested.params), reported, ctx, by, via);
		},
		NodeKind.Identifier => {
			reportMutableCapture(node, false, params, reported, ctx, by);
			reportBoundCapture(node, ctx, by, via);
		},
		NodeKind.BinaryExpr | NodeKind.UpdateExpr => {
			const target = node.kind == NodeKind.UpdateExpr ? (node.data as UpdateExprData).updateArg
				: writesItsLeft((node.data as BinaryExprData).operator) ? (node.data as BinaryExprData).left : null;
			if (target != null) reportMutableCapture(target, true, params, reported, ctx, by);
			forEachChild(node, (child: Node): void => { walkForMutableCaptures(child, params, reported, ctx, by, via); });
		},
		// Binding positions: the identifiers under a pattern DECLARE names, they
		// do not read the enclosing scope. Walking them would look the name up
		// outside the thunk and misreport a same-named mutable as captured.
		NodeKind.ArrayPattern | NodeKind.ObjectPattern | NodeKind.ObjectPatternProp => {},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			walkForMutableCaptures(d.caseGuard, params, reported, ctx, by, via);
			walkForMutableCaptures(d.caseBody, params, reported, ctx, by, via);
		},
		_ => { forEachChild(node, (child: Node): void => { walkForMutableCaptures(child, params, reported, ctx, by, via); }); },
	};
}

function reportBoundCapture(node: Node, ctx: CheckerContext, by: string, via: Node[]): void {
	const sym = node.resolvedSym;
	const bound = boundRoutine(sym);
	if (bound == null || via.includes(bound)) return;
	via.push(bound);
	judgedAtDeclaration(ctx, sym!, by, via);
	via.pop();
}

// A parameter carries no Mutable flag, yet a thunk that assigns it rebinds the
// parent's slot, so a written parameter is a mutable capture like a `let`.
function reportMutableCapture(
	node: Node,
	written: boolean,
	params: string[],
	reported: string[],
	ctx: CheckerContext,
	by: string,
): void {
	if (node.kind != NodeKind.Identifier) return;
	const d = node.data as IdentifierData;
	for (const p of params) { if (p == d.name) return; }
	for (const r of reported) { if (r == d.name) return; }
	// The lookup is by NAME against the scope of the spawn call site —
	// the thunk's own scopes are already popped by the time this runs.
	// A local declared inside the thunk that shadows an outer mutable
	// would resolve to the outer symbol here, so require the identifier
	// to actually point at it (resolvedSym is set by the body check that
	// ran just before; fall back to the name match when it is absent).
	const sym = lookupSymbol(ctx.table, d.name);
	if (sym == null || (node.resolvedSym != null && node.resolvedSym != sym)) return;
	if (!hasFlag(sym, SymbolFlag.Mutable) && !(written && sym.symbolKind == SymbolKind.Parameter)) return;
	addError(ctx, "mutable variable '" + d.name + "' cannot be captured by " + by + " — use const or move", node.location.line, node.location.column);
	reported.push(d.name);
}

function writesItsLeft(op: string): boolean {
	return op.endsWith("=") && op != "==" && op != "===" && op != "!=" && op != "!==" && op != "<=" && op != ">=";
}

export function checkSpawnCaptures(ctx: CheckerContext, closureNode: Node, spawnNode: Node): void {
	if (closureNode == null) return;
	let closure = closureNode;
	if (closure.kind == NodeKind.CallExpr) {
		const iifeCallee = (closure.data as CallExprData).callee;
		if (iifeCallee.kind == NodeKind.ArrowFunction) closure = (iifeCallee.data as ArrowFunctionData).arrowBody;
	}
	const source = peelHidden(closure);
	if (source.kind != NodeKind.ArrowFunction && source.kind != NodeKind.FunctionExpr && !isSendableFunction(source.nodeType)) {
		const sym = source.kind == NodeKind.Identifier ? source.resolvedSym : null;
		if (sym == null || !judgedAtDeclaration(ctx, sym, "spawn")) {
			const name = source.kind == NodeKind.CallExpr ? describeExpr((source.data as CallExprData).callee) + "(...)" : describeExpr(source);
			addError(ctx, `'${name}' is a function value that may capture mutable state, so spawn cannot run it on another thread — spawn a function declaration or a closure, or declare '${name}' as Sendable<F>`,
				source.location.line, source.location.column);
			return;
		}
	} else {
		checkClosureCaptures(ctx, source, "spawn");
		refuseViewResult(ctx, source);
	}
	requireSpawnSafe(ctx, closure, "spawn runs this thunk on another thread", spawnNode);
	refuseBorrowedAwaitable(ctx, closure, spawnNode);
	if (isIsolatedThunk(ctx, source)) spawnNode.flags = spawnNode.flags.incl(NodeFlag.Isolated);
	else spawnNode.flags = spawnNode.flags.excl(NodeFlag.Isolated);
}

function reachesAwaitable(t: Type | null, seen: Type[]): boolean {
	if (t == null || seen.includes(t)) return false;
	if (isAwaitable(t)) return true;
	if (!typeCarriesRef(t)) return false;
	seen.push(t);
	return match (t.kind) {
		TypeKind.Alias | TypeKind.Ref | TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Distinct
			| TypeKind.Borrow | TypeKind.Lent | TypeKind.Sink | TypeKind.Var | TypeKind.Cursor => reachesAwaitable(t.typeReturn, seen),
		TypeKind.Union | TypeKind.Tuple | TypeKind.Struct | TypeKind.GenericInstance | TypeKind.Varargs => {
			for (const c of t.typeChildren) { if (reachesAwaitable(c, seen)) return true; }
			return false;
		},
		_ => false,
	};
}

function borrowedRoot(n: Node, borrowed: Symbol[]): Symbol | null {
	let cur = peelView(n);
	while (cur.kind == NodeKind.MemberExpr || cur.kind == NodeKind.ArrayAccess) {
		cur = peelView(cur.kind == NodeKind.MemberExpr ? (cur.data as MemberExprData).object : (cur.data as ArrayAccessData).array);
	}
	const sym = cur.kind == NodeKind.Identifier ? cur.resolvedSym : null;
	return sym != null && borrowed.includes(sym) ? sym : null;
}

function borrowedAwaitableUse(node: Node | null, borrowed: Symbol[]): Node | null {
	if (node == null) return null;
	const p = peelView(node);
	if (p.kind == NodeKind.AwaitExpr) {
		const arg = peelView((p.data as AwaitExprData).awaitArg);
		if (borrowedRoot(arg, borrowed) != null && isAwaitable(arg.nodeType)) return null;
	}
	if (p.kind == NodeKind.CallExpr) {
		const d = p.data as CallExprData;
		const callee = peelView(d.callee);
		if (callee.kind == NodeKind.MemberExpr) {
			const receiver = (callee.data as MemberExprData).object;
			if (borrowedRoot(receiver, borrowed) != null && reachesAwaitable(receiver.nodeType, [])) return receiver;
		}
		if (!keepsArgumentsInFrame(p)) {
			const inCallee = borrowedAwaitableUse(d.callee, borrowed);
			if (inCallee != null) return inCallee;
			for (const a of d.arguments) {
				if (borrowedRoot(a, borrowed) != null) continue;
				const inArg = borrowedAwaitableUse(a, borrowed);
				if (inArg != null) return inArg;
			}
			return null;
		}
	}
	if ((p.kind == NodeKind.Identifier || p.kind == NodeKind.MemberExpr || p.kind == NodeKind.ArrayAccess) && borrowedRoot(p, borrowed) != null) {
		return reachesAwaitable(p.nodeType, []) ? p : null;
	}
	let found: Node | null = null;
	forEachChild(p, (child: Node): void => { if (found == null) found = borrowedAwaitableUse(child, borrowed); });
	return found;
}

function refuseBorrowedAwaitable(ctx: CheckerContext, fn: Node, at: Node): void {
	const thunk = spawnedClosure(peelHidden(fn));
	const views: Symbol[] = [];
	const moved: Symbol[] = [];
	collectBorrowCaptures(ctx, thunk, views, moved);
	const borrowed = views.filter((v: Symbol): boolean => !moved.includes(v) && reachesAwaitable(v.symbolType, []));
	if (borrowed.length == 0) return;
	const use = borrowedAwaitableUse(routineParamsAndBody(thunk).body, borrowed);
	if (use == null) return;
	const name = describeExpr(use);
	addError(ctx, `spawn's task uses '${name}', a promise it only borrows, other than by awaiting it; a promise is counted and settled on the thread that made it, and a borrowed view takes no count, so a task may only await it — await '${name}' in the task, or attach the callback outside the task`,
		use.location.line, use.location.column);
}

function isIsolatedThunk(ctx: CheckerContext, thunk: Node): boolean {
	if (thunk.kind == NodeKind.Identifier) {
		const sym = thunk.resolvedSym;
		return sym != null && sym.symbolKind == SymbolKind.Function && isModuleScoped(ctx, sym);
	}
	if (thunk.kind != NodeKind.ArrowFunction && thunk.kind != NodeKind.FunctionExpr) return false;
	return !takesReferenceCapture(ctx, routineParamsAndBody(thunk).body);
}

function isModuleScoped(ctx: CheckerContext, sym: Symbol): boolean {
	const home = scopeHolding(ctx.table, sym);
	return home != null && (home.scopeKind == ScopeKind.Global || home.scopeKind == ScopeKind.Module);
}

// The BORROW captures of a thunk: a ref-carrying binding of the spawn site's frame that the
// thunk neither moves in nor shares through an atomic count.
function collectBorrowCaptures(ctx: CheckerContext, node: Node | null, views: Symbol[], moved: Symbol[]): void {
	if (node == null || node.kind == NodeKind.ArrayPattern || node.kind == NodeKind.ObjectPattern || node.kind == NodeKind.ObjectPatternProp) return;
	if (node.kind == NodeKind.MoveExpr) {
		const arg = peelHidden((node.data as MoveExprData).moveArg);
		if (arg.resolvedSym != null) moved.push(arg.resolvedSym!);
	}
	const sym = node.kind == NodeKind.Identifier ? node.resolvedSym : null;
	if (sym != null && (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter) && !views.includes(sym)
		&& lookupSymbol(ctx.table, sym.name) == sym && !hasFlag(sym, SymbolFlag.Global) && !isModuleScoped(ctx, sym)
		&& typeCarriesRef(sym.symbolType) && !isAtomicRef(sym.symbolType)) views.push(sym);
	forEachChild(node, (child: Node): void => { collectBorrowCaptures(ctx, child, views, moved); });
}

function takesReferenceCapture(ctx: CheckerContext, node: Node | null): boolean {
	if (node == null || node.kind == NodeKind.ArrayPattern || node.kind == NodeKind.ObjectPattern || node.kind == NodeKind.ObjectPatternProp) return false;
	const sym = node.kind == NodeKind.Identifier ? node.resolvedSym : null;
	if (sym != null && lookupSymbol(ctx.table, sym.name) == sym && !hasFlag(sym, SymbolFlag.Global) && !isModuleScoped(ctx, sym)) {
		if (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter) return typeCarriesRef(sym.symbolType);
		return sym.symbolKind == SymbolKind.Function;
	}
	let found = false;
	forEachChild(node, (child: Node): void => { if (!found) found = takesReferenceCapture(ctx, child); });
	return found;
}

interface HandleFrame {
	ctx: CheckerContext;
	ownSpawns: boolean;
	returnsLeave: boolean;
	locals: Symbol[];
	holders: Symbol[];
	binds: HandleFlow[];
	stores: HandleFlow[];
	via: Node | null;
	viaName: string;
	trail: Node[];
	awaited: Node[];
}

interface HandleFlow {
	sym: Symbol;
	value: Node;
	whole: boolean;
}

export function refuseBorrowingHandleEscapes(ctx: CheckerContext, body: Node): void {
	checkHandleFrame({ ctx, ownSpawns: true, returnsLeave: true, locals: [], holders: [], binds: [], stores: [], via: null, viaName: "", trail: [], awaited: [] }, body);
}

function checkHandleFrame(f: HandleFrame, body: Node): void {
	collectFrameLocals(body, f.locals);
	collectHandleFlows(f, body);
	let grew = true;
	while (grew) grew = spreadHolders(f);
	walkHandleUses(f, body);
	if (body.kind != NodeKind.BlockStmt && body.kind != NodeKind.Program) refuseReturnedHandle(f, body);
}

function refuseReturnedHandle(f: HandleFrame, value: Node | null): void {
	if (f.returnsLeave && carriesHandle(f, value)) refuseHandleEscape(f, value!, "returning it");
}

function isNestedRoutine(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr
		|| n.kind == NodeKind.ClassDecl || n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ConstructorDecl;
}

function collectFrameLocals(node: Node, out: Symbol[]): void {
	if (isNestedRoutine(node)) return;
	if (node.kind == NodeKind.ArrayPattern || node.kind == NodeKind.ObjectPattern) {
		collectPatternSyms(node, out);
		return;
	}
	if ((node.kind == NodeKind.VariableDecl || node.kind == NodeKind.ForOfStmt) && node.resolvedSym != null && !hasFlag(node.resolvedSym!, SymbolFlag.Global)) out.push(node.resolvedSym!);
	forEachChild(node, (child: Node): void => { collectFrameLocals(child, out); });
}

function collectPatternSyms(n: Node | null, out: Symbol[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.Identifier) {
		if (n.resolvedSym != null && !hasFlag(n.resolvedSym!, SymbolFlag.Global)) out.push(n.resolvedSym!);
	} else if (n.kind == NodeKind.ArrayPattern) {
		for (const e of (n.data as ArrayPatternData).patternElements) collectPatternSyms(e, out);
	} else if (n.kind == NodeKind.ObjectPattern) {
		for (const p of (n.data as ObjectPatternData).patternProps) collectPatternSyms(p, out);
	} else if (n.kind == NodeKind.ObjectPatternProp) {
		collectPatternSyms((n.data as ObjectPatternPropData).propAlias, out);
	}
}

function bindElements(f: HandleFrame, pattern: Node | null, value: Node): void {
	const syms: Symbol[] = [];
	collectPatternSyms(pattern, syms);
	for (const s of syms) f.binds.push({ sym: s, value, whole: false });
}

function isAssignOp(op: string): boolean {
	return op == "=" || op == "??=" || op == "||=" || op == "&&=";
}

function elementWriteRoot(target: Node): Symbol | null {
	if (target.kind != NodeKind.ArrayAccess) return null;
	const array = peelView((target.data as ArrayAccessData).array);
	return array.kind == NodeKind.Identifier ? array.resolvedSym : null;
}

function arrayReceiver(call: Node): Symbol | null {
	const callee = peelView((call.data as CallExprData).callee);
	if (callee.kind != NodeKind.MemberExpr) return null;
	const object = peelView((callee.data as MemberExprData).object);
	if (object.kind != NodeKind.Identifier || object.resolvedSym == null) return null;
	let t = peelThrough(object.resolvedSym!.symbolType, PEEL_ALIAS);
	if (t != null && t.kind == TypeKind.Ref && t.typeReturn != null) t = peelThrough(t.typeReturn!, PEEL_ALIAS);
	return t != null && t.kind == TypeKind.Array ? object.resolvedSym : null;
}

function collectHandleFlows(f: HandleFrame, node: Node | null): void {
	if (node == null || isNestedRoutine(node)) return;
	if (node.kind == NodeKind.VariableDecl) {
		const init = (node.data as VariableDeclData).initializer;
		if (init != null && node.resolvedSym != null) f.binds.push({ sym: node.resolvedSym!, value: init, whole: true });
	} else if (node.kind == NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		bindElements(f, d.destrPattern, d.destrInit);
	} else if (node.kind == NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		if (node.resolvedSym != null) f.binds.push({ sym: node.resolvedSym!, value: d.forOfIterable, whole: false });
		bindElements(f, d.forOfPattern, d.forOfIterable);
	} else if (node.kind == NodeKind.BinaryExpr && isAssignOp((node.data as BinaryExprData).operator)) {
		const d = node.data as BinaryExprData;
		const target = peelView(d.left);
		if (target.kind == NodeKind.Identifier && target.resolvedSym != null) f.binds.push({ sym: target.resolvedSym!, value: d.right, whole: true });
		const into = elementWriteRoot(target);
		if (into != null) f.stores.push({ sym: into, value: d.right, whole: true });
	} else if (node.kind == NodeKind.CallExpr) {
		const into = arrayReceiver(node);
		if (into != null) {
			for (const a of (node.data as CallExprData).arguments) f.stores.push({ sym: into, value: a, whole: true });
		}
	}
	forEachChild(node, (child: Node): void => { collectHandleFlows(f, child); });
}

function addHolder(f: HandleFrame, sym: Symbol): boolean {
	if (!f.locals.includes(sym) || f.holders.includes(sym)) return false;
	f.holders.push(sym);
	return true;
}

function spreadHolders(f: HandleFrame): boolean {
	let grew = false;
	for (const b of f.binds) {
		if (!f.holders.includes(b.sym)) {
			if (carriesHandle(f, b.value) && addHolder(f, b.sym)) grew = true;
		} else if (!isAwaitable(b.sym.symbolType) && holdAliasRoots(f, b.value)) {
			grew = true;
		}
	}
	for (const s of f.stores) {
		if (carriesHandle(f, s.value) && addHolder(f, s.sym)) grew = true;
	}
	return grew;
}

function holdAliasRoots(f: HandleFrame, n: Node | null): boolean {
	if (n == null) return false;
	const p = peelView(n);
	return match (p.kind) {
		NodeKind.Identifier => p.resolvedSym != null && addHolder(f, p.resolvedSym!),
		NodeKind.MemberExpr => holdAliasRoots(f, (p.data as MemberExprData).object),
		NodeKind.ArrayAccess => holdAliasRoots(f, (p.data as ArrayAccessData).array),
		NodeKind.MoveExpr => holdAliasRoots(f, (p.data as MoveExprData).moveArg),
		NodeKind.CallExpr => {
			const callee = peelView((p.data as CallExprData).callee);
			return callee.kind == NodeKind.MemberExpr && holdAliasRoots(f, (callee.data as MemberExprData).object);
		},
		NodeKind.ConditionalExpr => {
			const d = p.data as ConditionalExprData;
			const a = holdAliasRoots(f, d.ternaryConsequent);
			return holdAliasRoots(f, d.ternaryAlternate) || a;
		},
		NodeKind.BinaryExpr => {
			const d = p.data as BinaryExprData;
			if (isAssignOp(d.operator)) return holdAliasRoots(f, d.right);
			if (d.operator != "??" && d.operator != "||" && d.operator != "&&") return false;
			const a = holdAliasRoots(f, d.left);
			return holdAliasRoots(f, d.right) || a;
		},
		_ => false,
	};
}

function ownsContainer(f: HandleFrame, sym: Symbol, seen: Symbol[]): boolean {
	if (!f.locals.includes(sym)) return false;
	if (seen.includes(sym)) return true;
	seen.push(sym);
	for (const b of f.binds) {
		if (b.sym == sym && (!b.whole || !isFreshContainer(f, b.value, seen))) return false;
	}
	return true;
}

function isFreshContainer(f: HandleFrame, n: Node, seen: Symbol[]): boolean {
	const p = peelView(n);
	if (p.kind == NodeKind.ArrayLiteral || p.kind == NodeKind.NullLiteral) return true;
	if (p.kind == NodeKind.Identifier) return p.resolvedSym != null && ownsContainer(f, p.resolvedSym!, seen);
	if (p.kind != NodeKind.ConditionalExpr) return false;
	const d = p.data as ConditionalExprData;
	return isFreshContainer(f, d.ternaryConsequent, seen) && isFreshContainer(f, d.ternaryAlternate, seen);
}

function holdsAwaitable(t: Type | null, seen: Type[]): boolean {
	if (t == null || isAwaitable(t)) return true;
	if (seen.includes(t) || !typeCarriesRef(t)) return false;
	seen.push(t);
	return match (t.kind) {
		TypeKind.String | TypeKind.CString | TypeKind.StringLiteral | TypeKind.Ptr => false,
		TypeKind.Alias | TypeKind.Ref | TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Distinct
			| TypeKind.Borrow | TypeKind.Lent | TypeKind.Sink | TypeKind.Var => holdsAwaitable(t.typeReturn, seen),
		TypeKind.Union | TypeKind.Tuple | TypeKind.Struct | TypeKind.GenericInstance | TypeKind.Varargs => {
			for (const c of t.typeChildren) { if (holdsAwaitable(c, seen)) return true; }
			return false;
		},
		_ => true,
	};
}

function isBorrowingSpawn(f: HandleFrame, p: Node): boolean {
	return f.ownSpawns && p.kind == NodeKind.CallExpr && p.resolvedSym != null && p.resolvedSym.builtinKind == "PromiseSpawn" && !p.flags.has(NodeFlag.Isolated);
}

function keepsArgumentsInFrame(call: Node): boolean {
	return call.resolvedSym != null && call.resolvedSym.builtinKind.startsWith("Promise");
}

function anyCarriesHandle(f: HandleFrame, nodes: Node[]): boolean {
	for (const n of nodes) { if (carriesHandle(f, n)) return true; }
	return false;
}

function carriesHandle(f: HandleFrame, n: Node | null): boolean {
	if (n == null) return false;
	const p = peelView(n);
	return match (p.kind) {
		NodeKind.Identifier => p.resolvedSym != null && f.holders.includes(p.resolvedSym!),
		NodeKind.CallExpr => isBorrowingSpawn(f, p) || callCarriesHandle(f, p),
		NodeKind.ArrayLiteral => anyCarriesHandle(f, (p.data as ArrayLiteralData).elements),
		NodeKind.SpreadExpr => carriesHandle(f, (p.data as SpreadExprData).spreadArg),
		NodeKind.MoveExpr => carriesHandle(f, (p.data as MoveExprData).moveArg),
		NodeKind.ConditionalExpr => carriesHandle(f, (p.data as ConditionalExprData).ternaryConsequent) || carriesHandle(f, (p.data as ConditionalExprData).ternaryAlternate),
		NodeKind.MatchExpr => {
			for (const c of (p.data as MatchExprData).matchCases) {
				const b = (c.data as MatchCaseData).caseBody;
				if (b.kind != NodeKind.BlockStmt && carriesHandle(f, b)) return true;
			}
			return false;
		},
		NodeKind.BinaryExpr => {
			const d = p.data as BinaryExprData;
			if (isAssignOp(d.operator) || d.operator == ",") return carriesHandle(f, d.right);
			return (d.operator == "??" || d.operator == "||" || d.operator == "&&") && (carriesHandle(f, d.left) || carriesHandle(f, d.right));
		},
		NodeKind.MemberExpr => carriesHandle(f, (p.data as MemberExprData).object) && holdsAwaitable(p.nodeType, []),
		NodeKind.ArrayAccess => carriesHandle(f, (p.data as ArrayAccessData).array) && holdsAwaitable(p.nodeType, []),
		NodeKind.AwaitExpr | NodeKind.NewExpr | NodeKind.ObjectLiteral | NodeKind.ArrowFunction | NodeKind.FunctionExpr
			| NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral | NodeKind.BigIntLiteral
			| NodeKind.RegexLiteral | NodeKind.UnaryExpr | NodeKind.UpdateExpr => false,
		_ => containsHandle(f, p) && holdsAwaitable(p.nodeType, []),
	};
}

function callCarriesHandle(f: HandleFrame, call: Node): boolean {
	if (!holdsAwaitable(call.nodeType, [])) return false;
	const d = call.data as CallExprData;
	const callee = peelView(d.callee);
	if (callee.kind == NodeKind.MemberExpr && carriesHandle(f, (callee.data as MemberExprData).object)) return true;
	return keepsArgumentsInFrame(call) && anyCarriesHandle(f, d.arguments);
}

function containsHandle(f: HandleFrame, n: Node | null): boolean {
	if (n == null || isNestedRoutine(n)) return false;
	if (n.kind == NodeKind.Identifier) return n.resolvedSym != null && f.holders.includes(n.resolvedSym!);
	if (isBorrowingSpawn(f, n)) return true;
	let found = false;
	forEachChild(n, (child: Node): void => { if (!found) found = containsHandle(f, child); });
	return found;
}

function capturedHolder(f: HandleFrame, n: Node | null): Node | null {
	if (n == null) return null;
	if (n.kind == NodeKind.Identifier) return n.resolvedSym != null && f.holders.includes(n.resolvedSym!) ? n : null;
	let found: Node | null = null;
	forEachChild(n, (child: Node): void => { if (found == null) found = capturedHolder(f, child); });
	return found;
}

function refuseHandleEscape(f: HandleFrame, at: Node, how: string): void {
	const site = f.via ?? at;
	const inside = f.via == null ? "" : ` (in '${f.viaName}' at ${at.location.line}:${at.location.column}, which was lent the handle)`;
	addError(f.ctx, `a spawn whose task borrows from this scope is joined when the scope exits, so its handle stays here: ${how} would let the handle outlive that join${inside}; await it in this scope, or let the task capture only copies, moved values, Arc<T> or Locked<T> so its handle is an ordinary promise`,
		site.location.line, site.location.column);
}

function refuseUnlessKept(f: HandleFrame, left: Node, value: Node): void {
	const target = peelView(left);
	if (target.kind == NodeKind.Identifier && target.resolvedSym != null && f.locals.includes(target.resolvedSym!)) return;
	const into = elementWriteRoot(target);
	if (into == null || !f.locals.includes(into)) refuseHandleEscape(f, value, "storing it in '" + describeExpr(left) + "'");
	else if (!ownsContainer(f, into, [])) refuseHandleEscape(f, value, "storing it in '" + describeExpr(left) + "', an array this scope did not create,");
}

function checkHandleArguments(f: HandleFrame, call: Node): void {
	if (keepsArgumentsInFrame(call)) return;
	const d = call.data as CallExprData;
	const into = arrayReceiver(call);
	for (let i = 0; i < d.arguments.length; i += 1) {
		const a = d.arguments[i];
		if (!carriesHandle(f, a)) continue;
		if (into == null || !f.locals.includes(into)) {
			const unlent = lendRefusal(f, call, i);
			if (unlent != null) refuseHandleEscape(f, a, "passing it to '" + describeExpr(d.callee) + "'" + unlent);
		} else if (!ownsContainer(f, into, [])) refuseHandleEscape(f, a, "passing it to '" + describeExpr(d.callee) + "', an array this scope did not create,");
	}
	const callee = peelView(d.callee);
	if (callee.kind != NodeKind.MemberExpr || !carriesHandle(f, (callee.data as MemberExprData).object)) return;
	for (const a of d.arguments) checkHandleCallback(f, a);
}

function lendTargets(call: Node): Symbol[] {
	const sym = call.resolvedSym ?? peelView((call.data as CallExprData).callee).resolvedSym;
	if (sym == null) return [];
	const targets: Symbol[] = [sym!];
	const entry = dispatchEntryFor(sym!);
	if (entry != null && !entry.overloaded) {
		for (const o of dispatchOverridesFor(entry.classSym, entry.methodName)) targets.push(o.sym);
	}
	return targets;
}

function lendRefusal(f: HandleFrame, call: Node, i: int32): string | null {
	const routines: Node[] = [];
	const external: boolean[] = [];
	for (const t of lendTargets(call)) {
		const r = routineParts(t);
		if (r == null || r.paramSyms == null) return "";
		routines.push(r);
		external.push(hasFlag(t, SymbolFlag.ImportC) || routineBody(r) == null);
	}
	if (routines.length == 0) return "";
	for (let k = 0; k < routines.length; k += 1) {
		const r = routines[k];
		if (firstArgParam(r, call) + i >= r.paramSyms!.length) return "";
		const formal = r.paramSyms![firstArgParam(r, call) + i];
		if (!isReadonlyView(formal.symbolType)) return `, whose parameter '${formal.name}' is not Readonly<...>: declare it Readonly<...> to lend the handle for the call,`;
		if (external[k]) return ", which has no body to check,";
		if (isAsyncFunctionNode(r) && !f.awaited.includes(call)) return ", an async function whose call is not awaited in place,";
	}
	for (const r of routines) checkLentBody(f, call, r, r.paramSyms![firstArgParam(r, call) + i]);
	return null;
}

function checkLentBody(f: HandleFrame, call: Node, routine: Node, formal: Symbol): void {
	if (f.trail.includes(routine)) return;
	const name = describeExpr((call.data as CallExprData).callee);
	const g: HandleFrame = { ctx: f.ctx, ownSpawns: false, returnsLeave: true, locals: [], holders: [formal], binds: [], stores: [], via: f.via ?? call, viaName: f.via == null ? name : f.viaName, trail: f.trail.concat([routine]), awaited: [] };
	checkHandleFrame(g, routineBody(routine)!);
}

function checkHandleCallback(f: HandleFrame, arg: Node): void {
	const p = peelView(arg);
	if (p.kind == NodeKind.ArrowFunction || p.kind == NodeKind.FunctionExpr) {
		const body = routineParamsAndBody(p).body;
		if (body == null) return;
		const g: HandleFrame = { ctx: f.ctx, ownSpawns: false, returnsLeave: false, locals: [], holders: [], binds: [], stores: [], via: f.via, viaName: f.viaName, trail: f.trail, awaited: [] };
		if (p.paramSyms != null) {
			for (const s of p.paramSyms!) { if (holdsAwaitable(s.symbolType, [])) g.holders.push(s); }
		}
		checkHandleFrame(g, body);
		return;
	}
	const t = p.nodeType;
	if (t == null || t.kind != TypeKind.Function) return;
	for (const c of t.typeChildren) {
		if (holdsAwaitable(c, [])) {
			refuseHandleEscape(f, arg, "passing it to '" + describeExpr(arg) + "'");
			return;
		}
	}
}

function walkHandleUses(f: HandleFrame, node: Node | null): void {
	if (node == null) return;
	if (isNestedRoutine(node)) {
		const held = capturedHolder(f, node);
		if (held != null) refuseHandleEscape(f, held, "capturing it in a closure");
		return;
	}
	match (node.kind) {
		NodeKind.VariableDecl => {
			const init = (node.data as VariableDeclData).initializer;
			if (node.resolvedSym != null && !f.locals.includes(node.resolvedSym!) && carriesHandle(f, init)) refuseHandleEscape(f, init!, "storing it in '" + (node.data as VariableDeclData).declName + "'");
		},
		NodeKind.ReturnStmt => refuseReturnedHandle(f, (node.data as ReturnStmtData).argument),
		NodeKind.YieldExpr => {
			const arg = (node.data as YieldExprData).yieldArg;
			if (carriesHandle(f, arg)) refuseHandleEscape(f, arg, "yielding it");
		},
		NodeKind.ThrowStmt => {
			const arg = (node.data as ThrowStmtData).throwArg;
			if (carriesHandle(f, arg)) refuseHandleEscape(f, arg, "throwing it");
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (isAssignOp(d.operator) && carriesHandle(f, d.right)) refuseUnlessKept(f, d.left, d.right);
		},
		NodeKind.CallExpr => checkHandleArguments(f, node),
		NodeKind.AwaitExpr => { f.awaited.push(peelView((node.data as AwaitExprData).awaitArg)); },
		NodeKind.NewExpr => {
			for (const a of (node.data as NewExprData).newArguments) {
				if (carriesHandle(f, a)) refuseHandleEscape(f, a, "passing it to a constructor");
			}
		},
		NodeKind.ObjectLiteral => {
			for (const p of (node.data as ObjectLiteralData).properties) {
				if (carriesHandle(f, p)) refuseHandleEscape(f, p, "storing it in an object");
			}
		},
		_ => {},
	};
	forEachChild(node, (child: Node): void => { walkHandleUses(f, child); });
}

function holdsView(t: Type | null, seen: Type[]): boolean {
	if (t == null || seen.includes(t) || t.kind == TypeKind.Ptr) return false;
	if (isReadonlyView(t)) return true;
	seen.push(t);
	return match (t.kind) {
		TypeKind.Ref | TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Distinct => holdsView(t.typeReturn, seen),
		TypeKind.Union | TypeKind.Tuple | TypeKind.Struct | TypeKind.GenericInstance => {
			for (const c of t.typeChildren) { if (holdsView(c, seen)) return true; }
			return false;
		},
		_ => false,
	};
}

function refuseViewResult(ctx: CheckerContext, thunk: Node): void {
	const fn = thunk.nodeType;
	if (fn != null && fn.kind == TypeKind.Function && holdsView(fn.typeReturn, [])) {
		addError(ctx, `spawn thunk returns ${typeDisplayName(fn.typeReturn)}, which reaches a value the parent only lends to the task; a borrowed view never leaves the task as its result — return a copy, or a scalar or string read out of it (PARALOCK E24)`,
			thunk.location.line, thunk.location.column);
		return;
	}
	const body = routineParamsAndBody(thunk).body;
	if (body == null) return;
	const results: Node[] = [];
	if (body.kind == NodeKind.BlockStmt) collectResults(body, results);
	else results.push(body);
	for (const r of results) {
		const captured = closureCaptureIn(ctx, r, []);
		if (captured == null) continue;
		const name = (captured.data as IdentifierData).name;
		addError(ctx, `spawn thunk returns a closure that captures '${name}', which the parent only lends to the task; a closure never carries a borrowed capture out of the task — return a scalar or string read out of '${name}', or build the closure after the await (PARALOCK E24)`,
			captured.location.line, captured.location.column);
		return;
	}
}

function collectResults(node: Node, out: Node[]): void {
	if (node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.FunctionDecl) return;
	if (node.kind == NodeKind.ReturnStmt) {
		const a = (node.data as ReturnStmtData).argument;
		if (a != null) out.push(a);
		return;
	}
	forEachChild(node, (child: Node): void => { collectResults(child, out); });
}

// The closure value a thunk result carries: a closure literal, one inside an object or array
// literal or a branch, or a thunk-local binding initialized to one.
function closureCaptureIn(ctx: CheckerContext, n: Node | null, seen: Symbol[]): Node | null {
	if (n == null) return null;
	const p = peelView(n);
	if (p == null) return null;
	return match (p.kind) {
		NodeKind.ArrowFunction | NodeKind.FunctionExpr => borrowedCapture(ctx, p),
		NodeKind.ObjectLiteral => firstCapture(ctx, (p.data as ObjectLiteralData).properties, seen),
		NodeKind.ArrayLiteral => firstCapture(ctx, (p.data as ArrayLiteralData).elements, seen),
		NodeKind.ConditionalExpr => {
			const d = p.data as ConditionalExprData;
			const a = closureCaptureIn(ctx, d.ternaryConsequent, seen);
			return a != null ? a : closureCaptureIn(ctx, d.ternaryAlternate, seen);
		},
		NodeKind.MatchExpr => {
			const bodies: Node[] = [];
			for (const c of (p.data as MatchExprData).matchCases) bodies.push((c.data as MatchCaseData).caseBody);
			return firstCapture(ctx, bodies, seen);
		},
		NodeKind.Identifier => {
			const sym = p.resolvedSym;
			if (sym == null || seen.includes(sym) || lookupSymbol(ctx.table, sym.name) == sym) return null;
			const decl = sym.declNode;
			if (decl == null || decl.kind != NodeKind.VariableDecl) return null;
			seen.push(sym);
			return closureCaptureIn(ctx, (decl.data as VariableDeclData).initializer, seen);
		},
		_ => null,
	};
}

function firstCapture(ctx: CheckerContext, nodes: Node[], seen: Symbol[]): Node | null {
	for (const n of nodes) {
		const c = closureCaptureIn(ctx, n, seen);
		if (c != null) return c;
	}
	return null;
}

// A binding the closure reads from outside the thunk lives in the env the parent lends,
// at any nesting depth: the scope at the spawn site still resolves it to the same symbol.
function borrowedCapture(ctx: CheckerContext, node: Node): Node | null {
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym == null || sym.name == "this" || hasFlag(sym, SymbolFlag.Global)) return null;
		if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter) return null;
		return lookupSymbol(ctx.table, sym.name) == sym ? node : null;
	}
	if (node.kind == NodeKind.ArrayPattern || node.kind == NodeKind.ObjectPattern || node.kind == NodeKind.ObjectPatternProp) return null;
	const hit: (Node | null)[] = [null];
	forEachChild(node, (child: Node): void => { if (hit[0] == null) hit[0] = borrowedCapture(ctx, child); });
	return hit[0];
}

function spawnEffectOf(fn: Node, e: Effect, views: Symbol[] = []): EffectCause | null {
	if (fn.kind != NodeKind.Identifier) return walkWithViews(fn, e, views);
	const sym = aliasTarget(fn.resolvedSym);
	if (sym == null) return null;
	if (sym.symbolKind == SymbolKind.Function) return routineEffect(sym, e);
	const bound = constBindingInitializer(sym);
	if (bound == null) return null;
	const declared = peelHidden(bound);
	const isRoutine = declared.kind == NodeKind.FunctionDecl || declared.kind == NodeKind.ArrowFunction || declared.kind == NodeKind.FunctionExpr;
	return isRoutine ? walkWithViews(declared, e, views) : null;
}

function spawnedClosure(fn: Node): Node {
	if (fn.kind != NodeKind.Identifier || fn.resolvedSym == null || fn.resolvedSym!.symbolKind == SymbolKind.Function) return fn;
	const bound = constBindingInitializer(aliasTarget(fn.resolvedSym));
	return bound != null ? peelHidden(bound) : fn;
}

function requireSpawnSafe(ctx: CheckerContext, fn: Node, runs: string, at: Node): void {
	const views: Symbol[] = [];
	const moved: Symbol[] = [];
	collectBorrowCaptures(ctx, spawnedClosure(peelHidden(fn)), views, moved);
	const borrowed = views.filter((v: Symbol): boolean => !moved.includes(v));
	deferEffectCheck(at, "spawnSafe", (ctx: CheckerContext): void => {
		const stored = spawnEffectOf(peelHidden(fn), Effect.StoresBorrowed, borrowed);
		if (stored != null) addError(ctx, runs + ", but it " + stored.text + "; " + storedValueName(stored.site) + " is a view the task does not own and a view takes no count, so pass it to a routine whose parameters are Readonly (the borrow form), or store an explicit copy of it (clone or spread) when the container must own its elements", at.location.line, at.location.column);
		const c = spawnEffectOf(peelHidden(fn), Effect.SpawnUnsafe);
		if (c == null) return;
		addError(ctx, runs + ", but it " + c.text + "; module state crosses threads only as a const value, a Locked<T> or an Arc<T>", at.location.line, at.location.column);
	});
}

struct RoutineParts { params: string[]; body: Node | null; }

function routineParamsAndBody(closure: Node): RoutineParts {
	if (closure.kind == NodeKind.ArrowFunction) {
		const ad = closure.data as ArrowFunctionData;
		return { params: ad.arrowParams, body: ad.arrowBody };
	}
	if (closure.kind == NodeKind.FunctionExpr) {
		const fd = closure.data as FunctionExprData;
		return { params: fd.funcExprParams, body: fd.funcExprBody };
	}
	if (closure.kind == NodeKind.FunctionDecl) {
		const fd = closure.data as FunctionDeclData;
		return { params: fd.params, body: fd.fnBody };
	}
	return { params: [], body: null };
}

function isLockedSection(ctx: CheckerContext, sym: Symbol | null): boolean {
	const origin = sym != null && sym.instantiatedFrom != null ? sym.instantiatedFrom : sym;
	return origin != null && origin.symbolKind == SymbolKind.Function && (origin.name == "lockedUpdate" || origin.name == "lockedRead")
		&& !isOutsideResolvedStd(ctx, origin.modulePath);
}

function lockCallbackEffect(fn: Node): EffectCause | null {
	if (fn.kind == NodeKind.ArrowFunction || fn.kind == NodeKind.FunctionExpr) return walkEffect(fn, Effect.Suspends);
	const sym = fn.kind == NodeKind.Identifier ? aliasTarget(fn.resolvedSym) : null;
	if (sym != null && sym.symbolKind == SymbolKind.Function) return routineEffect(sym, Effect.Suspends);
	const bound = sym != null ? constBindingInitializer(sym) : null;
	if (bound != null) {
		const declared = peelHidden(bound);
		if (declared.kind == NodeKind.ArrowFunction || declared.kind == NodeKind.FunctionExpr) return walkEffect(declared, Effect.Suspends);
	}
	return { site: fn, text: "is a function value at " + fn.location.line + ":" + fn.location.column };
}

export function refuseSuspendingLockCallback(ctx: CheckerContext, call: Node): void {
	if (call.kind != NodeKind.CallExpr || !isLockedSection(ctx, call.resolvedSym)) return;
	const args = (call.data as CallExprData).arguments;
	if (args.length != 2) return;
	const name = call.resolvedSym!.instantiatedFrom != null ? call.resolvedSym!.instantiatedFrom!.name : call.resolvedSym!.name;
	deferEffectCheck(call, "lockCallback", (ctx: CheckerContext): void => {
		const c = lockCallbackEffect(peelHidden(args[1]));
		if (c == null) return;
		addError(ctx, "the callback of '" + name + "' runs while the Locked cell is held and must not spawn, await or call a function value, but it " + c.text, call.location.line, call.location.column);
	});
}


function checkClosureCaptures(ctx: CheckerContext, closure: Node, by: string, via: Node[] = []): void {
	const parts = routineParamsAndBody(closure);
	const body = parts.body;
	const reported: string[] = [];
	if (body != null) {
		walkForMutableCaptures(body, parts.params, reported, ctx, by, via);
		if (ctx.currentActor != null && via.length == 0) {
			const actorReported: string[] = [];
			walkActorSpawnRules(ctx, body, actorReported);
		}
	}
}

export function checkSendableSource(ctx: CheckerContext, expr: Node): boolean {
	const source = peelHidden(expr);
	const mark = ctx.errors.length;
	if (source.kind == NodeKind.ArrowFunction || source.kind == NodeKind.FunctionExpr || source.kind == NodeKind.Identifier) {
		requireSpawnSafe(ctx, source, "a Sendable function may run on another thread", expr);
	}
	if (source.kind == NodeKind.ArrowFunction || source.kind == NodeKind.FunctionExpr) {
		checkClosureCaptures(ctx, source, "a Sendable function");
		return ctx.errors.length == mark;
	}
	const sym = source.kind == NodeKind.Identifier ? source.resolvedSym : null;
	if (sym != null && judgedAtDeclaration(ctx, sym)) return ctx.errors.length == mark;
	const name = describeExpr(source);
	addError(ctx, `'${name}' is a plain function value that may capture mutable state, so it does not convert to Sendable<F> — pass a function declaration or a closure, or declare '${name}' as Sendable<F>`,
		expr.location.line, expr.location.column);
	return false;
}

function judgedAtDeclaration(ctx: CheckerContext, bindingSym: Symbol, by: string = "a Sendable function", via: Node[] = []): boolean {
	const sym = aliasTarget(bindingSym)!;
	const home = scopeHolding(ctx.table, sym);
	if (home == null) return false;
	const routine = sym.symbolKind == SymbolKind.Function;
	if (routine && (home.scopeKind == ScopeKind.Global || home.scopeKind == ScopeKind.Module)) return true;
	const bound = constBindingInitializer(sym);
	const declared = routine ? sym.declNode : bound != null ? peelHidden(bound) : null;
	if (declared == null || (declared.kind != NodeKind.FunctionDecl && declared.kind != NodeKind.ArrowFunction && declared.kind != NodeKind.FunctionExpr)) return false;
	const here = ctx.table.current;
	ctx.table.current = home;
	checkClosureCaptures(ctx, declared, by, via);
	ctx.table.current = here;
	return true;
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

export function isCurrentActorRef(n: Node): boolean {
	const p = peelHidden(n);
	if (p == null || p.kind != NodeKind.Identifier) return false;
	if (isThisIdent(p)) return true;
	const init = constBindingInitializer(p.resolvedSym);
	return init != null && isCurrentActorRef(init);
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
	const actorSym = ctx.currentActor;
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

function holdsActor(t: Type | null, actorSym: Symbol, seen: Type[]): boolean {
	if (t == null || seen.includes(t)) return false;
	if (t.sym == actorSym) return true;
	seen.push(t);
	if (holdsActor(t.typeReturn, actorSym, seen)) return true;
	if (t.kind == TypeKind.Function) return false;
	for (const c of t.typeChildren) {
		if (holdsActor(c, actorSym, seen)) return true;
	}
	return false;
}

function walkActorSpawnRules(ctx: CheckerContext, node: Node | null, reportedKeys: string[]): void {
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
			const name = (node.data as IdentifierData).name;
			if (name == "this") {
				if (pushIfNew(reportedKeys, "this")) {
					addError(ctx, "spawn thunk inside an actor method cannot capture 'this' — borrow individual fields instead (PARALOCK S1/E61)", node.location.line, node.location.column);
				}
				return;
			}
			const sym = lookupSymbol(ctx.table, name);
			if (sym == null || (node.resolvedSym != null && node.resolvedSym != sym)) return;
			if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter) return;
			if (holdsActor(sym.symbolType, ctx.currentActor!, []) && pushIfNew(reportedKeys, "v:" + name)) {
				addError(ctx, `spawn thunk inside an actor method cannot capture '${name}', which can hold the actor 'this' — borrow individual fields instead (PARALOCK S1/E61)`, node.location.line, node.location.column);
				return;
			}
			const bound = constBindingInitializer(aliasTarget(sym));
			const routine = bound != null ? peelHidden(bound) : null;
			if (routine != null && (routine.kind == NodeKind.ArrowFunction || routine.kind == NodeKind.FunctionExpr) && pushIfNew(reportedKeys, "c:" + name)) {
				walkActorSpawnRules(ctx, routineParamsAndBody(routine).body, reportedKeys);
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

test "a lifecycle hook anywhere in a payload fails only the walks given a hook predicate" {
	const hooked = createStruct("Hooked", ["n"], [int32Type()], true);
	const outer = createStruct("Outer", ["h", "n"], [hooked, int32Type()], true);
	const declaresHook = (owner: Type): boolean => owner == hooked;
	assert !isDeepSendable(outer, SendLeaf.String as int32, declaresHook);
	assert !isDeepSendable(hooked, SendLeaf.GenericParam as int32, declaresHook);
	assert isArcPointeeSendable(outer);
	assert isLockedPayloadSendable(outer);
	assert isTypeSendable(outer);
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

function storedValueName(site: Node): string {
	const value = site.kind == NodeKind.BinaryExpr ? (site.data as BinaryExprData).right : site;
	const name = describeExpr(value);
	return name == "an expression" ? "the stored value" : "'" + name + "'";
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
	const scope: FreshScope = {
		moveNames: w.moveNames,
		table: w.ctx.table,
		buildsAlone: (site: Node): boolean => {
			requireNoSideEffect(site, w);
			return true;
		},
	};
	if (rhs == null || w.reported || isFreshValue(rhs, scope)) return;
	reportNotSoleOwner(w, what + " at " + rhs.location.line + ":" + rhs.location.column + " is not a fresh value (a literal, `new`, `move`, or a call whose receiver and arguments are fresh)");
}

function requireFreshBinding(init: Node | null, w: OwnerWalk): void {
	const lit = init == null ? null : peelView(init);
	const held = lit != null && (lit.kind == NodeKind.ArrowFunction || lit.kind == NodeKind.FunctionExpr) ? borrowedCapture(w.ctx, lit) : null;
	if (held == null || w.reported) { requireFresh(init, "the value bound to '" + w.name + "'", w); return; }
	reportNotSoleOwner(w, "the closure bound to '" + w.name + "' captures '" + describeExpr(held) + "' at " + held.location.line + ":" + held.location.column + ", and the parent still names that captured graph");
}

function requireNoSideEffect(site: Node, w: OwnerWalk): void {
	deferEffectCheck(site, "noSideEffect", (ctx: CheckerContext): void => {
		if (w.reported) return;
		const c = site.kind == NodeKind.NewExpr ? newEffect(site, Effect.SideEffect) : callEffect(site, Effect.SideEffect);
		if (c != null) reportNotSoleOwner(w, "a call with side effects may keep an alias of it: " + c.text);
	});
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
				requireFreshBinding(d.initializer, w);
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
			if (ownerIsReceiver && locBefore(node.location, w.site)) requireNoSideEffect(node, w);
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
