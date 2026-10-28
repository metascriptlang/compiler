import { Node, NodeKind, NodeFlag, SymbolFlag, CallExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";

// A JS callee tells an absent argument from `null`, so a trailing optional argument the call left out
// reaches an extern routine as no argument; one written `null` stays.
export function lowerJsExternOmittedArgs(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind != NodeKind.CallExpr) return node;
		const d = node.data as CallExprData;
		const sym = d.callee.resolvedSym;
		if (sym == null || (!sym.symFlags.has(SymbolFlag.ImportC) && !sym.symFlags.has(SymbolFlag.NativeMethod))) return node;
		if (sym.nativeName.contains("#")) return node;
		while (d.arguments.length > 0 && d.arguments[d.arguments.length - 1].flags.has(NodeFlag.OmittedArg)) d.arguments.pop();
		return node;
	});
}
