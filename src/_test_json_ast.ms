import { parseSource } from "./parser/statements/validation";
import { NodeKind } from "./ast/node";

const src = "export class JSON {\n\t@builtin(\"JsonParse\")\n\tstatic extern parse<T>(input: string): Result<T, string>;\n\n\t@builtin(\"JsonStringify\")\n\tstatic extern stringify<T>(value: T): string;\n}";

const result = parseSource(src, "/test.ms");
if (result.ok) {
	const program = result.value;
	for (const stmt of program.data.statements) {
		if (stmt.kind === NodeKind.ExportDecl) {
			const inner = stmt.data.exportedNode;
			if (inner.kind === NodeKind.ClassDecl) {
				const cd = inner.data;
				console.log("class:", cd.className, "body length:", cd.classBody.length);
				for (let i = 0; i < cd.classBody.length; i++) {
					const m = cd.classBody[i];
					console.log("  member[" + i + "]:", m.kind, "resolvedSym:", m.resolvedSym);
					if (m.kind === NodeKind.DecoratedDecl) {
						const dd = m.data;
						console.log("    inner:", dd.decoratedNode.kind);
						if (dd.decoratedNode.kind === NodeKind.MethodDecl) {
							const md = dd.decoratedNode.data;
							console.log("    method:", md.methodName, "static:", md.methodIsStatic, "flags:", md.methodFlags);
						}
					} else if (m.kind === NodeKind.MethodDecl) {
						console.log("    method:", m.data.methodName, "static:", m.data.methodIsStatic);
					}
				}
			}
		}
	}
} else {
	console.log("parse error:", result.error);
}
