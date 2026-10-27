// Runtime renames for the Raiser — `setTimeout`, `setInterval`, their clears and the async
// driver `msAsyncStart` are externs the VM has no host function for: a host function cannot
// call a closure back. The calls are rewritten to the portable runtime in std/core/promise,
// which waits on a VM timer or runs the stepper from the event loop. Runs after the async
// bridge, which emits `msAsyncStart`.

import { Node, NodeKind, CallExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { runtimeRef } from "../util";

function runtimeNameOf(native: string): string {
	return match (native) {
		"msSetTimeout" => "msTimerSetTimeout",
		"msSetInterval" => "msTimerSetInterval",
		"msClearTimeout" => "msTimerClear",
		"msClearInterval" => "msTimerClear",
		"msAsyncStart" => "msRaiserAsyncStart",
		_ => "",
	};
}

export function lowerRuntimeNames(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (n: Node): Node => {
		if (n.kind != NodeKind.CallExpr) return n;
		const d = n.data as CallExprData;
		if (d.callee.kind != NodeKind.Identifier || d.callee.resolvedSym == null) return n;
		const runtime = runtimeNameOf(d.callee.resolvedSym.nativeName);
		if (runtime == "") return n;
		d.callee = runtimeRef(runtime, d.callee.location);
		return n;
	});
}
