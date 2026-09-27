import { Node, NodeKind, CallExprData, ActorDeclData, DecoratedDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, addError } from "./context";
import { isAsyncFunctionNode, isSpawnCall, isFunctionLike } from "./freestanding";
import { lex } from "../lexer/lexer";
import { parseProgram } from "../parser/statements/core";
import { createState } from "../parser/context";

export const JS_SYNC_AWAIT_MSG: string = "await in a function that is not async: the JS backend has no blocking wait, so every caller of this function would receive a Promise — declare it async and await its calls, or move this code to the module top level";

interface SaScope {
	awaitAllowed: boolean;
	reported: boolean;
}

function isListed(list: Node[], node: Node): boolean {
	for (const n of list) {
		if (n == node) return true;
	}
	return false;
}

function listActorMethods(actor: Node, awaitingFns: Node[]): void {
	for (const member of (actor.data as ActorDeclData).actorBody) {
		const m = member.kind == NodeKind.DecoratedDecl ? (member.data as DecoratedDeclData).decoratedNode : member;
		if (m.kind == NodeKind.MethodDecl) awaitingFns.push(m);
	}
}

function saWalk(node: Node, out: Node[], scope: SaScope, awaitingFns: Node[]): void {
	if (node == null) return;
	if (isFunctionLike(node)) {
		const inner: SaScope = { awaitAllowed: isAsyncFunctionNode(node) || isListed(awaitingFns, node), reported: false };
		forEachChild(node, (child: Node): void => { saWalk(child, out, inner, awaitingFns); });
		return;
	}
	if (node.kind == NodeKind.TestDecl) {
		const inner: SaScope = { awaitAllowed: true, reported: false };
		forEachChild(node, (child: Node): void => { saWalk(child, out, inner, awaitingFns); });
		return;
	}
	if (node.kind == NodeKind.ActorDecl) listActorMethods(node, awaitingFns);
	if (isSpawnCall(node)) {
		const args = (node.data as CallExprData).arguments;
		if (args.length > 0 && isFunctionLike(args[0])) awaitingFns.push(args[0]);
	}
	if (node.kind == NodeKind.AwaitExpr && !scope.awaitAllowed && !scope.reported) {
		out.push(node);
		scope.reported = true;
	}
	forEachChild(node, (child: Node): void => { saWalk(child, out, scope, awaitingFns); });
}

export function collectSyncAwait(program: Node): Node[] {
	const out: Node[] = [];
	if (program == null) return out;
	saWalk(program, out, { awaitAllowed: true, reported: false }, []);
	return out;
}

export function refuseSyncAwaitOnJs(ctx: CheckerContext, program: Node): void {
	for (const hit of collectSyncAwait(program)) {
		addError(ctx, JS_SYNC_AWAIT_MSG, hit.location.line, hit.location.column);
	}
}

function syncAwaitHits(src: string): int32 {
	const lr = lex(src);
	if (!lr.ok) return -1;
	const pr = parseProgram(createState(lr.value));
	if (!pr.ok) return -1;
	return collectSyncAwait(pr.value).length as int32;
}

test "an await in a sync function is reported" { assert syncAwaitHits("function f(): void { await g(); }") == 1; }

test "several awaits in one sync body are one report" { assert syncAwaitHits("function f(): void { await g(); await h(); }") == 1; }

test "an await in an async function is allowed" { assert syncAwaitHits("async function f(): Promise<void> { await g(); }") == 0; }

test "a top-level await is allowed" { assert syncAwaitHits("await g();") == 0; }

test "an await in a test body is allowed" { assert syncAwaitHits("test \"t\" { await g(); }") == 0; }

test "a sync arrow inside an async function is its own scope" { assert syncAwaitHits("async function f(): Promise<void> { const k = () => { await g(); }; }") == 1; }

test "an await in a sync method is reported" { assert syncAwaitHits("class C { m(): void { await g(); } }") == 1; }

test "an await in an actor method is allowed" { assert syncAwaitHits("actor A { m(): int32 { await g(); return 1; } }") == 0; }
