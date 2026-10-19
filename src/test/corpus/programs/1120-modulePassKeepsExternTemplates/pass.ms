import { Node, NodeKind } from "std/meta";

export macro externPass(mod: Node): Node {
	let out: Node[] = [];
	for (const s of mod.programStmts) {
		if (s.kind == NodeKind.ExportDecl && s.exportedDecl.kind == NodeKind.FunctionDecl && s.exportedDecl.nativeName != "") {
			const d = s.exportedDecl;
			s.exportedDecl = {
				kind: NodeKind.FunctionDecl, line: d.line, column: d.column, fnName: d.fnName, params: d.params,
				fnParamTypes: d.fnParamTypes, fnBody: d.fnBody, fnFlags: d.fnFlags, fnReturnType: d.fnReturnType,
				fnDefaults: d.fnDefaults, nativeName: d.nativeName, nameLocation: { line: d.line, column: d.column },
			};
		}
		out.push(s);
	}
	return { kind: NodeKind.Program, line: mod.line, column: mod.column, programStmts: out };
}
