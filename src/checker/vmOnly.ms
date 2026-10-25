import { ModuleGraph, ErrorSeverity, createModuleError, findModule } from "../module/graph";
import { Node, NodeKind, Symbol, SymbolKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { lookupModuleProgram } from "./instantiate";
import { hasFlag, setFlag, SymbolFlag } from "./symbol";

interface Reference {
	owner: Symbol | null;
	callee: Symbol;
	modulePath: string;
	line: int32;
	column: int32;
}

function isVmOnlyExtern(sym: Symbol, stdPath: string): boolean {
	return sym.symbolKind == SymbolKind.Function && hasFlag(sym, SymbolFlag.ImportC) && sym.modulePath.startsWith(stdPath + "/meta/");
}

function collectReferences(program: Node, modulePath: string): Reference[] {
	const refs: Reference[] = [];
	const visit = (n: Node, owner: Symbol | null): void => {
		const k = n.kind;
		if (k == NodeKind.MacroDecl || k == NodeKind.ComptimeBlock || k == NodeKind.MethodDecl || k == NodeKind.ConstructorDecl) return;
		let inner = owner;
		if (k == NodeKind.FunctionDecl && n.resolvedSym != null) inner = n.resolvedSym;
		const sym = n.resolvedSym;
		if ((k == NodeKind.Identifier || k == NodeKind.MemberExpr) && sym != null && sym.symbolKind == SymbolKind.Function) {
			refs.push({ owner, callee: sym, modulePath, line: n.location.line, column: n.location.column });
		}
		forEachChild(n, (child: Node): void => visit(child, inner));
	};
	visit(program, null);
	return refs;
}

export function markVmOnlyRoutines(graph: ModuleGraph, stdPath: string): void {
	const refs: Reference[] = [];
	for (const mod of graph.modules) {
		const program = lookupModuleProgram(mod.path);
		if (program == null) continue;
		for (const r of collectReferences(program, mod.path)) refs.push(r);
	}
	const inferred = new HashMap<Symbol, string>();
	let changed = true;
	while (changed) {
		changed = false;
		for (const r of refs) {
			if (r.owner == null || inferred.has(r.owner) || hasFlag(r.owner, SymbolFlag.CompileTime)) continue;
			if (!isVmOnlyExtern(r.callee, stdPath) && !inferred.has(r.callee)) continue;
			inferred.set(r.owner, r.callee.name);
			setFlag(r.owner, SymbolFlag.CompileTime);
			changed = true;
		}
	}
	for (const r of refs) {
		if (r.owner != null) continue;
		const reason = inferred.has(r.callee) ? inferred.get(r.callee) : isVmOnlyExtern(r.callee, stdPath) ? "" : null;
		if (reason == null) continue;
		const because = reason == "" ? `'${r.callee.name}' is provided by the macro VM only` : `'${r.callee.name}' calls '${reason}', which the macro VM alone provides`;
		findModule(graph, r.modulePath).errors.push(createModuleError(`${because}, so it has no run-time code: call it from a macro`, r.line, r.column, ErrorSeverity.Error));
	}
}
