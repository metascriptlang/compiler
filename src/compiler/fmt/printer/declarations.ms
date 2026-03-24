// Declaration Printers — class, interface, enum, import, export, etc.

import {
	Node, NodeFlag,
	ImportDeclData, ExportDeclData,
	ClassDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData,
	ExternDeclData, DecoratedDeclData, TestDeclData, AssertStmtData,
	PropertyDeclData, MethodDeclData,
} from "../../../ast/node";
import { FormatOptions } from "../options";
import {
	Doc, docText, docGroup, docIndent, docLineSuffix,
	docLine, docSoftLine, docHardLine, docIfBreak, docNil, docJoin,
} from "../doc";
import { Token } from "../../../lexer/token";
import { callPrintNode } from "./callbacks";

export function printImportDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ImportDeclData;
	const parts: Doc[] = [docText("import ")];
	if (d.importNames.length > 0) {
		const names: Doc[] = [];
		for (let i = 0; i < d.importNames.length; i += 1) {
			if (d.importAliases[i] !== "" && d.importAliases[i] !== d.importNames[i]) {
				names.push(docText(d.importNames[i] + " as " + d.importAliases[i]));
			} else {
				names.push(docText(d.importNames[i]));
			}
		}
		// Prettier pattern: single specifier stays inline, multiple use group + indent + line
		if (names.length === 1) {
			parts.push(docText("{ "));
			parts.push(names[0]);
			parts.push(docText(" }"));
		} else {
			parts.push(docText("{"));
			parts.push(docIndent([docLine(), docJoin(names, docGroup([docText(","), docLine()]))]));
			parts.push(docIfBreak(docNil(), docText(",")));
			parts.push(docLine());
			parts.push(docText("}"));
		}
		parts.push(docText(" from "));
	}
	let q = "\"";
	if (options.singleQuote) { q = "'"; }
	parts.push(docText(q + d.importSource + q));
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printExportDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ExportDeclData;
	const prefix = ((node.flags & NodeFlag.ExportDefault) !== 0) ? "export default " : "export ";
	return docGroup([docText(prefix), callPrintNode(d.exportedDecl, options)]);
}

export function printTypeAliasDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeAliasDeclData;
	if (d.discriminantName !== "" && d.discriminantName !== null) {
		// Discriminated union: type X = match (disc: Enum) { ... }
		const parts: Doc[] = [docText("type " + d.aliasName + " = match (" + d.discriminantName + ": " + d.discriminantType + ") {")];
		for (let i = 0; i < d.variantKeys.length; i += 1) {
			parts.push(docLine());
			parts.push(docText("\t" + d.variantKeys[i] + " => " + d.variantTypes[i] + ","));
		}
		parts.push(docLine());
		parts.push(docText("}"));
		if (options.semi) parts.push(docText(";"));
		return docGroup(parts);
	}
	const parts: Doc[] = [docText("type " + d.aliasName + " = " + d.aliasType)];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printEnumDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as EnumDeclData;
	if (d.enumMembers.length === 0) return docText("enum " + d.enumName + " {}");
	const members: Doc[] = [];
	for (const m of d.enumMembers) {
		members.push(docText(m + ","));
	}
	return docGroup([
		docText("enum " + d.enumName + " {"),
		docIndent([docHardLine(), docJoin(members, docHardLine())]),
		docHardLine(),
		docText("}"),
	]);
}

function printStructLikeDecl(node: Node, keyword: string): Doc {
	const d = node.data as InterfaceDeclData;
	if (d.interfaceFields.length === 0) return docText(keyword + " " + d.interfaceName + " {}");

	// Build a map of comment line → comment text for inline comments on fields.
	// Comments on the InterfaceDecl node that have line > node start are field comments.
	const commentsByLine: Token[] = [];
	const remaining: Token[] = [];
	for (const comment of node.comments) {
		if (comment.line > node.location.line) {
			commentsByLine.push(comment);
		} else {
			remaining.push(comment);
		}
	}
	node.comments = remaining;

	const fields: Doc[] = [];
	let commentIdx = 0;
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		let field = d.interfaceFields[i];
		if (d.interfaceFieldTypes[i] !== "") {
			field = field + ": " + d.interfaceFieldTypes[i];
		}
		// Check if there's a trailing comment for this field (next comment in order)
		if (commentIdx < commentsByLine.length) {
			fields.push(docGroup([
				docText(field + ";"),
				docLineSuffix([docText(" " + commentsByLine[commentIdx].value)]),
			]));
			commentIdx = commentIdx + 1;
		} else {
			fields.push(docText(field + ";"));
		}
	}
	return docGroup([
		docText(keyword + " " + d.interfaceName + " {"),
		docIndent([docHardLine(), docJoin(fields, docHardLine())]),
		docHardLine(),
		docText("}"),
	]);
}

export function printInterfaceDecl(node: Node, options: FormatOptions): Doc {
	return printStructLikeDecl(node, "interface");
}

export function printStructDecl(node: Node, options: FormatOptions): Doc {
	return printStructLikeDecl(node, "struct");
}

export function printClassDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ClassDeclData;
	const parts: Doc[] = [docText("class " + d.className)];
	if (d.classExtends !== "") {
		parts.push(docText(" extends " + d.classExtends));
	}
	parts.push(docText(" {"));
	if (d.classBody.length > 0) {
		const members: Doc[] = [];
		for (const m of d.classBody) {
			members.push(callPrintNode(m, options));
		}
		parts.push(docIndent([docHardLine(), docJoin(members, docHardLine())]));
		parts.push(docHardLine());
	}
	parts.push(docText("}"));
	return docGroup(parts);
}

export function printExternDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ExternDeclData;
	const parts: Doc[] = [docText("extern " + d.externName)];
	if (d.nativeName !== "") {
		parts.push(docText(" from \"" + d.nativeName + "\""));
	}
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printDecoratedDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as DecoratedDeclData;
	const parts: Doc[] = [];
	for (const dec of d.decorators) {
		parts.push(callPrintNode(dec, options));
		parts.push(docHardLine());
	}
	parts.push(callPrintNode(d.decoratedNode, options));
	return docGroup(parts);
}

export function printTestDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as TestDeclData;
	let q = "\"";
	if (options.singleQuote) { q = "'"; }
	return docGroup([
		docText("test " + q + d.testName + q + " "),
		callPrintNode(d.testBody, options),
	]);
}

export function printAssertStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as AssertStmtData;
	const parts: Doc[] = [
		docText("assert "),
		callPrintNode(d.assertExpr, options),
	];
	if (d.assertMessage.length > 0) {
		parts.push(docText(" : \"" + d.assertMessage + "\""));
	}
	parts.push(docText(";"));
	return docGroup(parts);
}

export function printPropertyDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as PropertyDeclData;
	const parts: Doc[] = [];
	if (d.propIsStatic) {
		parts.push(docText("static "));
	}
	parts.push(docText(d.propName));
	if (d.propType !== "") {
		parts.push(docText(": " + d.propType));
	}
	if (d.propInitializer !== null) {
		parts.push(docText(" = ..."));
	}
	parts.push(docText(";"));
	return docGroup(parts);
}

export function printMethodDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as MethodDeclData;
	const params: Doc[] = [];
	for (let i = 0; i < d.methodParams.length; i += 1) {
		let p = d.methodParams[i];
		if (d.methodParamTypes[i] !== "") {
			p = p + ": " + d.methodParamTypes[i];
		}
		params.push(docText(p));
	}
	const parts: Doc[] = [];
	if (d.methodIsStatic) {
		parts.push(docText("static "));
	}
	parts.push(docText(d.methodName + "("));
	parts.push(docGroup([
		docIndent([docSoftLine(), docJoin(params, docGroup([docText(","), docLine()]))]),
		docSoftLine(),
	]));
	parts.push(docText(")"));
	if (d.methodReturnType !== "") {
		parts.push(docText(": " + d.methodReturnType));
	}
	parts.push(docText(" "));
	parts.push(callPrintNode(d.methodBody, options));
	return docGroup(parts);
}
