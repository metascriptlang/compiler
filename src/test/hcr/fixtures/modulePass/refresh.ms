import { Node, NodeKind, expansionFile } from "std/meta";

let entries: string[] = [];

function fileName(path: string): string {
	const cut = path.lastIndexOf("/") > path.lastIndexOf("\\") ? path.lastIndexOf("/") : path.lastIndexOf("\\");
	return path.slice(cut + 1);
}

export function registerComponent(how: string, file: string, name: string): void {
	entries.push(how + " " + fileName(file) + ":" + name);
}

export function noteTemplate(text: string): string {
	entries.push("template " + text);
	return text;
}

export function refreshLog(): string {
	const out = entries.join(",");
	entries = [];
	return out;
}

function isComponentName(name: string): boolean {
	if (name.length == 0) return false;
	const c = name.charCodeAt(0);
	return c >= 65 && c <= 90;
}

export macro refreshModule(mod: Node): Node {
	const file = expansionFile();
	const L = mod.line;
	const C = mod.column;
	let out: Node[] = [];
	let reregister: Node[] = [];
	let registrations: Node[] = [];
	for (const s of mod.programStmts) {
		let decl = s;
		if (s.kind == NodeKind.ExportDecl) decl = s.exportedDecl;
		if (decl.kind == NodeKind.FunctionDecl && isComponentName(decl.fnName)) {
			registrations.push({
				kind: NodeKind.ExprStmt, line: L, column: C,
				expr: { kind: NodeKind.CallExpr, line: L, column: C, callee: { kind: NodeKind.Identifier, line: L, column: C, name: "registerComponent" }, arguments: [
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: "register" },
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: file },
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: decl.fnName },
				] },
			});
			reregister.push({
				kind: NodeKind.ExprStmt, line: L, column: C,
				expr: { kind: NodeKind.CallExpr, line: L, column: C, callee: { kind: NodeKind.Identifier, line: L, column: C, name: "registerComponent" }, arguments: [
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: "reregister" },
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: file },
					{ kind: NodeKind.StringLiteral, line: L, column: C, value: decl.fnName },
				] },
			});
		}
		out.push(s);
	}
	for (const r of registrations) out.push(r);
	if (reregister.length > 0) {
		out.push({
			kind: NodeKind.DecoratedDecl, line: L, column: C,
			decorators: [{ kind: NodeKind.MacroInvocation, line: L, column: C, macroName: "afterReload", macroArgs: [], macroHasParens: false }],
			decoratedNode: {
				kind: NodeKind.FunctionDecl, line: L, column: C, fnName: "__refreshAfterReload", params: [], fnParamTypes: [],
				fnBody: { kind: NodeKind.BlockStmt, line: L, column: C, statements: reregister },
				fnFlags: "", fnReturnType: "void", fnDefaults: [], nativeName: "", nameLocation: { line: L, column: C },
			},
		});
	}
	return { kind: NodeKind.Program, line: mod.line, column: mod.column, programStmts: out };
}
