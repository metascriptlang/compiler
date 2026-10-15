import { Node, NodeKind } from "std/meta";

export macro rebuildLoops(mod: Node): Node {
	const out: Node[] = [];
	for (const s of mod.programStmts) {
		if (s.kind != NodeKind.ForOfStmt) {
			out.push(s);
			continue;
		}
		let pattern = s.forOfPattern;
		if (pattern != null && pattern.kind == NodeKind.ArrayPattern) {
			pattern = {
				kind: NodeKind.ArrayPattern, line: pattern.line, column: pattern.column,
				patternElements: pattern.patternElements, hasRestElement: pattern.hasRestElement, patternDefaults: pattern.patternDefaults,
			};
		}
		out.push({
			kind: NodeKind.ForOfStmt, line: s.line, column: s.column,
			forOfBinding: s.forOfBinding, forOfIsConst: s.forOfIsConst,
			forOfIterable: s.forOfIterable, forOfBody: s.forOfBody, forOfPattern: pattern,
		});
	}
	return { kind: NodeKind.Program, line: mod.line, column: mod.column, programStmts: out };
}
