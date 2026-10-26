// Timer lowering for the Raiser — `setTimeout`, `setInterval` and their clears are externs
// the VM has no host function for: a host function cannot call a closure back. The calls
// are rewritten to the timer runtime in std/core/promise, which waits on a VM timer and
// runs the callback from the event loop.

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
		_ => "",
	};
}

export function lowerTimers(program: Node, ctx: TransformContext): Node {
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
