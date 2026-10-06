import { Node, NodeKind, expansionFile } from "std/meta";

let entries: string[] = [];

function fileName(path: string): string {
	const cut = path.lastIndexOf("/") > path.lastIndexOf("\\") ? path.lastIndexOf("/") : path.lastIndexOf("\\");
	return path.slice(cut + 1);
}

export function registerComponent(file: string, name: string): void {
	entries.push("register " + fileName(file) + ":" + name);
}

export function noteRender(name: string): void {
	entries.push("render " + name);
}

export function refreshLog(): string {
	return entries.join(",");
}

function isComponentName(name: string): boolean {
	if (name.length == 0) return false;
	const c = name.charCodeAt(0);
	return c >= 65 && c <= 90;
}

export macro refreshModule(mod: Node): Node {
	const file = expansionFile();
	let out: Node[] = [];
	let registrations: Node[] = [];
	for (const s of mod.programStmts) {
		let decl = s;
		if (s.kind == NodeKind.ExportDecl) decl = s.exportedDecl;
		if (decl.kind == NodeKind.FunctionDecl && isComponentName(decl.fnName)) {
			const L = decl.line;
			const C = decl.column;
			const helper = "__refreshRender" + decl.fnName;
			out.push({
				kind: NodeKind.FunctionDecl, line: L, column: C, fnName: helper, params: [], fnParamTypes: [],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: [{
					kind: NodeKind.ExprStmt, line: L, column: C,
					expr: { kind: NodeKind.CallExpr, line: L, column: C, callee: { kind: NodeKind.Identifier, line: L, column: C, name: "noteRender" }, arguments: [{ kind: NodeKind.StringLiteral, line: L, column: C, value: decl.fnName }] },
				}] },
				fnFlags: "", fnReturnType: "void", fnDefaults: [], nativeName: "", nameLocation: { line: L, column: C },
			});
			let body: Node[] = [{
				kind: NodeKind.ExprStmt, line: L, column: C,
				expr: { kind: NodeKind.CallExpr, line: L, column: C, callee: { kind: NodeKind.Identifier, line: L, column: C, name: helper }, arguments: [] },
			}];
			for (const b of decl.fnBody.statements) body.push(b);
			decl.fnBody = { kind: NodeKind.BlockStmt, line: L, column: C, statements: body };
			registrations.push({
				kind: NodeKind.ExprStmt, line: L, column: C,
				expr: { kind: NodeKind.CallExpr, line: L, column: C, callee: { kind: NodeKind.Identifier, line: L, column: C, name: "registerComponent" }, arguments: [
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: file },
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: decl.fnName },
				] },
			});
		}
		out.push(s);
	}
	for (const r of registrations) out.push(r);
	return { kind: NodeKind.Program, line: mod.line, column: mod.column, programStmts: out };
}
