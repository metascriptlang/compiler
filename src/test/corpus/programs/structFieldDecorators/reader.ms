import { Node, NodeKind, bindSym, getImpl, stringValue } from "std/meta";

export macro viaDeclaration(): Node {
	const shape = getTypeArg();
	const decl = getImpl(bindSym(shape.typExprTypeName))!;
	let text = "";
	for (let i = 0; i < decl.interfaceFields.length; i += 1) {
		text = text + decl.interfaceFields[i] + ":";
		for (const dec of decl.interfaceFieldDecorators[i]) {
			text = text + "@" + dec.macroName + "(";
			let first = true;
			for (const arg of dec.macroArgs) {
				if (!first) text = text + ",";
				first = false;
				if (arg.kind === NodeKind.StringLiteral) {
					text = text + `S"${stringValue(arg)}"`;
				} else if (arg.kind === NodeKind.Identifier) {
					text = text + `I ${arg.name}`;
				} else if (arg.kind === NodeKind.MemberExpr) {
					const target = arg.object;
					if (target.kind === NodeKind.Identifier) text = text + `M ${target.name}.${arg.property}`;
				} else if (arg.kind === NodeKind.CallExpr) {
					const callee = arg.callee;
					if (callee.kind === NodeKind.MemberExpr) {
						const target = callee.object;
						if (target.kind === NodeKind.Identifier) text = text + `C ${target.name}.${callee.property}()`;
					}
				} else {
					text = text + "?";
				}
			}
			text = text + ")";
		}
		text = text + ";";
	}
	return { kind: NodeKind.StringLiteral, line: shape.line, column: shape.column, value: text };
}

export macro viaShape(): Node {
	const shape = getTypeArg();
	let text = "";
	for (let i = 0; i < shape.typExprFieldNames.length; i += 1) {
		text = text + shape.typExprFieldNames[i] + ":";
		for (const dec of shape.typExprFieldDecorators[i]) text = text + dec.macroName + ",";
		text = text + ";";
	}
	return { kind: NodeKind.StringLiteral, line: shape.line, column: shape.column, value: text };
}
