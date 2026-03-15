import { readFile } from "std/process";
import { parseSource } from "./parser/statements/validation";
import { NodeKind } from "./ast/node";
import { createContext, createExtensionRegistry } from "./checker/context";
import { collectDeclarations } from "./checker/collectPass";

const src = readFile("std/core/json/index.cms");
console.log("source length:", src.length);

const pr = parseSource(src);
if (!pr.ok) {
	console.log("PARSE ERROR:", pr.error);
} else {
	const program = pr.value;
	const stmts = program.data.statements;
	console.log("statements:", stmts.length);
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		console.log("stmt[" + i + "] kind:", stmt.kind);
		if (stmt.kind === NodeKind.ExportDecl) {
			const inner = stmt.data.exportedDecl;
			console.log("  export kind:", inner.kind);
			if (inner.kind === NodeKind.ClassDecl) {
				const cd = inner.data;
				console.log("  class:", cd.className, "body:", cd.classBody.length);
				for (let j = 0; j < cd.classBody.length; j += 1) {
					const m = cd.classBody[j];
					console.log("    member[" + j + "] kind:", m.kind);
					if (m.kind === NodeKind.DecoratedDecl) {
						const dd = m.data;
						console.log("      decorators:", dd.decorators.length);
						console.log("      decoratedNode:", dd.decoratedNode !== null ? "exists" : "NULL");
						if (dd.decoratedNode !== null) {
							console.log("      inner kind:", dd.decoratedNode.kind);
						}
					}
				}
			}
		}
	}
	// Now try collect pass
	const ctx = createContext();
	ctx.extensionRegistry = createExtensionRegistry();
	collectDeclarations(ctx, program);
	console.log("collectDeclarations OK");

	// Check resolvedSym
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt.kind === NodeKind.ExportDecl) {
			const inner = stmt.data.exportedDecl;
			if (inner.kind === NodeKind.ClassDecl) {
				const cd = inner.data;
				for (let j = 0; j < cd.classBody.length; j += 1) {
					const m = cd.classBody[j];
					if (m.kind === NodeKind.DecoratedDecl) {
						const dd = m.data;
						console.log("    after collect: member[" + j + "].resolvedSym:", m.resolvedSym !== null ? m.resolvedSym.name : "NULL");
						console.log("    dd.decoratedNode:", dd.decoratedNode !== null ? "exists" : "NULL");
						if (dd.decoratedNode !== null) {
							console.log("    dd.decoratedNode.kind:", dd.decoratedNode.kind);
						}
					}
				}
			}
		}
	}
}
