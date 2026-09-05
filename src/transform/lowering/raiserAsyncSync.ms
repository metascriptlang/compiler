// Raiser eager-sync async lowering — collapses the async surface to its
// synchronous equivalent for the single-threaded Raiser VM.
//
//   await X            → X
//   spawn(fn)          → fn()          (run the closure eagerly, inline)
//   waitFor(h)         → h             (the handle already holds the value)
//   Promise.resolve(v) → v
//
// A Promise<T> handle is just T once spawn runs eagerly, so a stored handle
// read later by waitFor/await is already the value. Bottom-up traversal makes
// `await spawn(fn)` fold to `fn()` in one pass (spawn rewrites first, then the
// enclosing await unwraps the result). Runs before lambda lifting so the
// closure invoked by an inlined spawn is lifted like any other.

import { Node, NodeKind, AwaitExprData, CallExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall } from "../util";

export function lowerRaiserAsyncSync(program: Node, ctx: TransformContext): Node {
	return walkNode(program, lowerAsyncNode);
}

function lowerAsyncNode(node: Node): Node {
	if (node.kind === NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		return d.awaitArg;
	}
	if (node.kind === NodeKind.CallExpr) {
		const sym = node.resolvedSym;
		if (sym === null) return node;
		const d = node.data as CallExprData;
		if (sym.builtinKind === "PromiseSpawn" && d.arguments.length === 1) {
			const invoked = makeCall(d.arguments[0], [], node.location);
			invoked.nodeType = node.nodeType;
			return invoked;
		}
		if (sym.builtinKind === "WaitFor" && d.arguments.length === 1) {
			return d.arguments[0];
		}
		if (sym.builtinKind === "PromiseResolve" && d.arguments.length === 1) {
			return d.arguments[0];
		}
	}
	return node;
}
