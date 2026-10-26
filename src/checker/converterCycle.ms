import { Node, NodeFlag, NodeKind, Symbol, SymbolKind, CallExprData, FunctionDeclData, MethodDeclData } from "../ast/node";
import { CheckerContext, addError } from "./context";
import { forEachChild } from "../ast/visitor";

interface CycleWalk {
	conv: Symbol;
	routine: Symbol;
	seen: HashSet<Node>;
	pending: Symbol[];
}

function routineBody(sym: Symbol): Node | null {
	const decl = sym.declNode;
	if (decl == null) return null;
	return match (decl.kind) {
		NodeKind.FunctionDecl => (decl.data as FunctionDeclData).fnBody,
		NodeKind.MethodDecl => (decl.data as MethodDeclData).methodBody,
		_ => null,
	};
}

function isRoutine(sym: Symbol): boolean {
	return sym.symbolKind == SymbolKind.Function || sym.symbolKind == SymbolKind.Method;
}

function appliesConverter(node: Node, conv: Symbol): boolean {
	if (node.kind != NodeKind.CallExpr || !node.flags.has(NodeFlag.ProtocolCall)) return false;
	const callee = (node.data as CallExprData).callee;
	return callee != null && callee.resolvedSym == conv;
}

function visitForCycle(ctx: CheckerContext, walk: CycleWalk, node: Node): void {
	if (walk.routine != walk.conv && walk.routine.modulePath == ctx.modulePath && appliesConverter(node, walk.conv)) {
		const conv = walk.conv.name;
		addError(
			ctx,
			`'${conv}' is applied implicitly in '${walk.routine.name}', which '${conv}' reaches through its calls`
				+ ` — the conversion would recurse; convert explicitly here or inside '${conv}'`,
			node.location.line,
			node.location.column,
		);
	}
	const target = node.resolvedSym;
	if (target != null && isRoutine(target) && routineBody(target) != null) {
		if (!walk.seen.has(target.declNode)) {
			walk.seen.add(target.declNode);
			walk.pending.push(target);
		}
	}
	forEachChild(node, (child: Node): void => {
		visitForCycle(ctx, walk, child);
	});
}

function reportCycleSites(ctx: CheckerContext, conv: Symbol): void {
	const walk: CycleWalk = { conv, routine: conv, seen: new HashSet<Node>(), pending: [conv] };
	if (conv.declNode != null) walk.seen.add(conv.declNode);
	while (walk.pending.length > 0) {
		const routine = walk.pending[walk.pending.length - 1];
		walk.pending.pop();
		const body = routineBody(routine);
		if (body == null) continue;
		walk.routine = routine;
		visitForCycle(ctx, walk, body);
	}
}

export function reportConverterCycles(ctx: CheckerContext): void {
	for (const conv of ctx.runtimeConverters) {
		if (conv.modulePath != ctx.modulePath) continue;
		reportCycleSites(ctx, conv);
	}
}
