import { Node, NodeFlag, NodeKind, Symbol, SymbolKind, SymbolFlag, CallExprData, FunctionDeclData, MethodDeclData } from "../ast/node";
import { CheckerContext, addError } from "./context";
import { hasFlag } from "./symbol";
import { forEachChild } from "../ast/visitor";

interface CycleWalk {
	conv: Symbol;
	routine: Symbol;
	seen: HashMap<string, boolean>;
	pending: Symbol[];
}

function routineBody(sym: Symbol): Node | null {
	const decl = sym.declNode;
	if (decl == null) return null;
	if (decl.kind == NodeKind.FunctionDecl) return (decl.data as FunctionDeclData).fnBody;
	if (decl.kind == NodeKind.MethodDecl) return (decl.data as MethodDeclData).methodBody;
	return null;
}

function routineKey(sym: Symbol): string {
	const decl = sym.declNode;
	const at = decl != null ? `${decl.location.line}:${decl.location.column}` : "";
	return `${sym.modulePath}|${sym.name}|${at}`;
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
	if (node == null) return;
	if (walk.routine != walk.conv && walk.routine.modulePath == ctx.modulePath && appliesConverter(node, walk.conv)) {
		addError(ctx, "'" + walk.conv.name + "' is applied implicitly in '" + walk.routine.name + "', which '" + walk.conv.name
			+ "' reaches through its calls — the conversion would recurse; convert explicitly here or inside '" + walk.conv.name + "'",
			node.location.line, node.location.column);
	}
	const target = node.resolvedSym;
	if (target != null && isRoutine(target) && routineBody(target) != null) {
		const key = routineKey(target);
		if (!walk.seen.has(key)) {
			walk.seen.set(key, true);
			walk.pending.push(target);
		}
	}
	forEachChild(node, (child: Node): void => {
		visitForCycle(ctx, walk, child);
	});
}

function reportCycleSites(ctx: CheckerContext, conv: Symbol): void {
	const walk: CycleWalk = { conv: conv, routine: conv, seen: new HashMap<string, boolean>(), pending: [conv] };
	walk.seen.set(routineKey(conv), true);
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
		if (hasFlag(conv, SymbolFlag.Imported) || conv.modulePath != ctx.modulePath) continue;
		reportCycleSites(ctx, conv);
	}
}
