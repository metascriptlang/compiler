// Actor sendability + this-write isolation rules. Leaf module: no calls out.

import { ActorDeclData, ArrayAccessData, ArrowFunctionData, BinaryExprData, CallExprData, DecoratedDeclData, FunctionExprData, HiddenDerefData, HiddenStdConvData, IdentifierData, MacroInvocationData, MatchCaseData, MemberExprData, MethodDeclData, MoveExprData, Node, NodeKind, OutExprData, PropertyDeclData, Symbol, Type, TypeKind, UpdateExprData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";
import { SymbolFlag, hasFlag, lookupSymbol } from "./symbol";
import { isPrimitiveKind, isStructType, typeDisplayName } from "./types";

export function hasNonisolatedField(actorSym: Symbol, fieldName: string): boolean {
	if (actorSym.declNode === null || actorSym.declNode.kind !== NodeKind.ActorDecl) return false;
	const actorBody = (actorSym.declNode.data as ActorDeclData).actorBody;
	for (const m of actorBody) {
		if (m.kind !== NodeKind.DecoratedDecl) continue;
		const dd = m.data as DecoratedDeclData;
		if (dd.decoratedNode === null || dd.decoratedNode.kind !== NodeKind.PropertyDecl) continue;
		if ((dd.decoratedNode.data as PropertyDeclData).propName !== fieldName) continue;
		for (const dec of dd.decorators) {
			if (dec.kind === NodeKind.MacroInvocation
				&& (dec.data as MacroInvocationData).macroName === "nonisolated") return true;
		}
	}
	return false;
}

// Type-level check: is the type safe to send (no mutable refs anywhere)?
// Follows reference isolation check: containsDangerousRefAux — recurse into structure.
function isTypeSendable(t: Type | null): boolean {
	if (t === null) return true;
	if (isPrimitiveKind(t.kind)) return true;
	return match (t.kind) {
		TypeKind.String => true,
		TypeKind.Struct when (isStructType(t)) => {
			for (const ft of t.typeChildren) {
				if (!isTypeSendable(ft)) return false;
			}
			return true;
		},
		TypeKind.Tuple => {
			for (const et of t.typeChildren) {
				if (!isTypeSendable(et)) return false;
			}
			return true;
		},
		TypeKind.GenericInstance => {
			if (t.typeReturn !== null && !isTypeSendable(t.typeReturn)) return false;
			for (const ta of t.typeChildren) {
				if (!isTypeSendable(ta)) return false;
			}
			return true;
		},
		TypeKind.Array => {
			return t.typeReturn !== null ? isTypeSendable(t.typeReturn) : true;
		},
		TypeKind.Ref | TypeKind.Function => false,
		_ => false,
	};
}

// Call-site check: combines type analysis with expression-level rules (move, const binding).
function isSendable(t: Type, argNode: Node): boolean {
	if (t === null) return true;
	// move always transfers ownership safely
	if (argNode !== null && argNode.kind === NodeKind.MoveExpr) return true;
	// If the type itself contains no refs, it's always sendable (value copy)
	if (isTypeSendable(t)) return true;
	// Ref<T> with const binding → SHARE rule (immutable, safe to share)
	if (t.kind === TypeKind.Ref) {
		if (argNode !== null && argNode.resolvedSym !== null
			&& !hasFlag(argNode.resolvedSym, SymbolFlag.Mutable)) return true;
		return false;
	}
	return false;
}

export function checkActorArgSendable(ctx: CheckerContext, argNode: Node, pi: number): void {
	const t = argNode.nodeType;
	if (t === null) return;
	if (isSendable(t, argNode)) return;
	const argLabel = argNode.kind === NodeKind.Identifier
		? "'" + (argNode.data as IdentifierData).name + "'"
		: `arg ${pi}`;
	const typedesc = typeDisplayName(t);
	const hint = match (t.kind) {
		TypeKind.Ref => {
			const varName = argNode.kind === NodeKind.Identifier ? " " + (argNode.data as IdentifierData).name : "";
			return ` — use \`move${varName}\` to transfer ownership`;
		},
		TypeKind.Function => " — closures may capture mutable state",
		_ => "",
	};
	addError(ctx, `actor methods only accept value types, \`move\`, or \`const\` references\n${typedesc} ${argLabel} is a mutable reference${hint}`,
		argNode.location.line, argNode.location.column);
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
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl || node.kind === NodeKind.FunctionExpr || node.kind === NodeKind.ArrowFunction) return;
	match (node.kind) {
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			let skip = false;
			for (const p of params) { if (p === d.name) skip = true; }
			for (const r of reported) { if (r === d.name) skip = true; }
			if (!skip) {
				// The lookup is by NAME against the scope of the spawn call site —
				// the thunk's own scopes are already popped by the time this runs.
				// A local declared inside the thunk that shadows an outer mutable
				// would resolve to the outer symbol here, so require the identifier
				// to actually point at it (resolvedSym is set by the body check that
				// ran just before; fall back to the name match when it is absent).
				const sym = lookupSymbol(ctx.table, d.name);
				const shadowed = node.resolvedSym !== null && node.resolvedSym !== sym;
				if (!shadowed && sym !== null && hasFlag(sym, SymbolFlag.Mutable)) {
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
	if (closureNode === null) return;
	let params: string[] = [];
	let body: Node | null = null;
	if (closureNode.kind === NodeKind.ArrowFunction) {
		const ad = closureNode.data as ArrowFunctionData;
		params = ad.arrowParams;
		body = ad.arrowBody;
	} else if (closureNode.kind === NodeKind.FunctionExpr) {
		const fd = closureNode.data as FunctionExprData;
		params = fd.funcExprParams;
		body = fd.funcExprBody;
	}
	const reported: string[] = [];
	if (body !== null) {
		walkForMutableCaptures(body, params, reported, ctx);
		if (ctx.currentActorName !== "") {
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
function peelHidden(n: Node): Node {
	let cur = n;
	while (cur !== null) {
		if (cur.kind === NodeKind.HiddenDeref) { cur = (cur.data as HiddenDerefData).expr; continue; }
		if (cur.kind === NodeKind.HiddenStdConv) { cur = (cur.data as HiddenStdConvData).convExpr; continue; }
		break;
	}
	return cur;
}

function isThisIdent(n: Node): boolean {
	const p = peelHidden(n);
	if (p === null) return false;
	if (p.kind !== NodeKind.Identifier) return false;
	return (p.data as IdentifierData).name === "this";
}

function writeChainRoot(n: Node): Node {
	let cur = peelHidden(n);
	while (cur !== null) {
		if (cur.kind === NodeKind.MemberExpr) { cur = peelHidden((cur.data as MemberExprData).object); continue; }
		if (cur.kind === NodeKind.ArrayAccess) { cur = peelHidden((cur.data as ArrayAccessData).array); continue; }
		break;
	}
	return cur;
}

function thisWriteFieldName(n: Node): string {
	let cur = peelHidden(n);
	while (cur !== null) {
		if (cur.kind === NodeKind.MemberExpr) {
			const d = cur.data as MemberExprData;
			if (isThisIdent(d.object)) return d.property;
			cur = peelHidden(d.object); continue;
		}
		if (cur.kind === NodeKind.ArrayAccess) { cur = peelHidden((cur.data as ArrayAccessData).array); continue; }
		break;
	}
	return "";
}

function pushIfNew(list: string[], key: string): boolean {
	for (const k of list) { if (k === key) return false; }
	list.push(key);
	return true;
}

function actorDeclaresMethod(ctx: CheckerContext, methodName: string): boolean {
	const actorSym = lookupSymbol(ctx.table, ctx.currentActorName);
	if (actorSym === null || actorSym.declNode === null) return false;
	if (actorSym.declNode.kind !== NodeKind.ActorDecl) return false;
	const body = (actorSym.declNode.data as ActorDeclData).actorBody;
	for (const m of body) {
		let mm = m;
		if (mm.kind === NodeKind.DecoratedDecl) {
			const dd = mm.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) mm = dd.decoratedNode;
		}
		if (mm.kind === NodeKind.MethodDecl && (mm.data as MethodDeclData).methodName === methodName) return true;
	}
	return false;
}

function reportThisFieldWrite(ctx: CheckerContext, target: Node, node: Node, reportedKeys: string[], verb: string): void {
	if (!isThisIdent(writeChainRoot(target))) return;
	if (isThisIdent(target)) return;
	const f = thisWriteFieldName(target);
	const label = f !== "" ? "'" + f + "'" : "state";
	if (pushIfNew(reportedKeys, "w:" + f)) {
		addError(ctx, "captured actor field " + label + " is read-only inside a spawn thunk — " + verb + " is not allowed; compute into a local and apply after await (PARALOCK S3/E62)", node.location.line, node.location.column);
	}
}

function walkActorSpawnRules(ctx: CheckerContext, node: Node, reportedKeys: string[]): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			const isAsgn = d.operator === "=" || d.operator === "+=" || d.operator === "-=" ||
				d.operator === "*=" || d.operator === "/=" || d.operator === "%=" ||
				d.operator === "&&=" || d.operator === "||=" || d.operator === "??=";
			if (isAsgn) {
				reportThisFieldWrite(ctx, d.left, node, reportedKeys, "assignment");
			}
			walkActorSpawnRules(ctx, d.left, reportedKeys);
			walkActorSpawnRules(ctx, d.right, reportedKeys);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			reportThisFieldWrite(ctx, d.updateArg, node, reportedKeys, "increment/decrement");
			walkActorSpawnRules(ctx, d.updateArg, reportedKeys);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			reportThisFieldWrite(ctx, d.moveArg, node, reportedKeys, "'move'");
			walkActorSpawnRules(ctx, d.moveArg, reportedKeys);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			reportThisFieldWrite(ctx, d.outArg, node, reportedKeys, "'out' argument");
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
			if ((node.data as IdentifierData).name === "this" && pushIfNew(reportedKeys, "this")) {
				addError(ctx, "spawn thunk inside an actor method cannot capture 'this' — borrow individual fields instead (PARALOCK S1/E61)", node.location.line, node.location.column);
			}
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			const nestedSpawn = node.resolvedSym !== null && node.resolvedSym.builtinKind === "PromiseSpawn";
			walkActorSpawnRules(ctx, d.callee, reportedKeys);
			let ai = 0;
			for (const arg of d.arguments) {
				if (!(nestedSpawn && ai === 0)) { walkActorSpawnRules(ctx, arg, reportedKeys); }
				ai = ai + 1;
			}
		},
		_ => { forEachChild(node, (child: Node): void => { walkActorSpawnRules(ctx, child, reportedKeys); }); },
	};
}

