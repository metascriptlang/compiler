// Declaration Printers — class, interface, enum, import, export, etc.

import {
	Node, NodeKind, NodeFlag, SourceLocation,
	ImportDeclData, ExportDeclData,
	ClassDeclData, ActorDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData,
	ExternDeclData, ExternKind, DecoratedDeclData, TestDeclData, AssertStmtData,
	PropertyDeclData, MethodDeclData, ConstructorDeclData, MacroDeclData, FunctionDeclData, makeLoc,
} from "../../../ast/node";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import {
	Doc, docText, docGroup, docIndent,
	docLine, docHardLine, docIfBreak, docNil, docJoin,
} from "../doc";
import { SourceComment } from "../comments";
import { withComments, danglingOf, danglingLines, danglingBlock, commentsWithin, markWithin, interleave, boxed, startLineOf, joinKeepingBlankLines } from "./commentDocs";
import { callPrintNode } from "./callbacks";
import { sourceByteAt, sourceSpan, writtenCommaBetween, writtenInitializer, writtenOptional, writtenTypeAfterOptional, unoptionalized, nativeFrom } from "./literals";
import { flagHas, flagGet, buildParamList, paramListInParens, genericsFor, writtenName, commentedList, paramListComments, headerAsWritten, printBlock, printCollapsibleBody, isSynthesized, takeStructAccessors } from "./statements";

function bodyComments(node: Node): SourceComment[] {
	const loc = node.location;
	if (loc.endLine == 0) return danglingOf(node);
	return commentsWithin(loc, makeLoc(loc.endLine, loc.endColumn));
}

function commentedSpecifiers(names: Doc[], locs: SourceLocation[], node: Node): Doc | null {
	const inner = bodyComments(node);
	if (inner.length == 0) return null;
	return commentedList(names, locs, inner, "{", "}");
}

function typeModifier(node: Node): string {
	return node.flags.has(NodeFlag.TypeModifier) ? "type " : "";
}

function specifierDocs(d: ImportDeclData): Doc[] {
	const names: Doc[] = [];
	for (let i = 0; i < d.importNames.length; i += 1) {
		const name = d.importTypeNames.includes(d.importNames[i]) ? "type " + d.importNames[i] : d.importNames[i];
		if (d.importAliases[i] != "" && d.importAliases[i] != d.importNames[i]) {
			names.push(docText(name + " as " + d.importAliases[i]));
		} else {
			names.push(docText(name));
		}
	}
	return names;
}

export function printImportDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ImportDeclData;
	// Namespace import: `import * as M from "..."` — single `*` specifier with alias.
	if (d.importNames.length == 1 && d.importNames[0] == "*") {
		let q = "\"";
		if (options.singleQuote) q = "'";
		const alias = d.importAliases[0];
		const head = "import " + typeModifier(node) + (alias != "" && alias != "*" ? "* as " + alias + " from " : "* from ");
		const tail = options.semi ? ";" : "";
		return docGroup([docText(head + q + d.importSource + q + tail)]);
	}
	const parts: Doc[] = [docText("import " + typeModifier(node))];
	if (d.importNames.length > 0) {
		const names = specifierDocs(d);
		// Prettier pattern: single specifier stays inline, multiple use group + indent + line
		const commented = commentedSpecifiers(names, d.nameLocations, node);
		if (commented != null) {
			parts.push(commented);
		} else if (names.length == 1) {
			parts.push(docText("{ "));
			parts.push(names[0]);
			parts.push(docText(" }"));
		} else {
			// Inner group: breaks independently from the rest of the import.
			// When broken: `{\n  name1,\n  name2,\n}` — when flat: `{ name1, name2 }`
			const nameParts: Doc[] = [docLine()];
			for (let i = 0; i < names.length; i += 1) {
				if (i > 0) {
					nameParts.push(docLine());
				}
				if (i < names.length - 1) {
					nameParts.push(docGroup([names[i], docText(",")]));
				} else {
					nameParts.push(names[i]);
					if (wantsTrailingComma(options, CommaContext.Collection)) {
						nameParts.push(docIfBreak(docText(","), docNil()));
					}
				}
			}
			parts.push(docGroup([
				docText("{"),
				docIndent(nameParts),
				docLine(),
				docText("}"),
			]));
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
	const isDefault = node.flags.has(NodeFlag.ExportDefault);
	// Re-export form: `export { ... } from "..."` — the exportedDecl is an
	// ImportDecl-shaped node. Inlining `printImportDecl` here would emit a
	// stray `import` keyword (`export import { ... } from ...`), so we
	// build the re-export form directly.
	if (!isDefault && d.exportedDecl != null && d.exportedDecl.kind == NodeKind.ImportDecl) {
		return printReExport(d.exportedDecl, node, options);
	}
	const prefix = isDefault ? "export default " : "export ";
	return docGroup([docText(prefix), callPrintNode(d.exportedDecl, options)]);
}

function printReExport(inner: Node, outer: Node, options: FormatOptions): Doc {
	const id = inner.data as ImportDeclData;
	let q = "\"";
	if (options.singleQuote) q = "'";
	// Star re-export: `export * from "..."` — single `*` specifier (no alias).
	if (id.importNames.length == 1 && id.importNames[0] == "*") {
		const alias = id.importAliases[0];
		const head = "export " + typeModifier(inner) + (alias != "" && alias != "*" ? "* as " + alias + " from " : "* from ");
		const tail = options.semi ? ";" : "";
		return docGroup([docText(head + q + id.importSource + q + tail)]);
	}
	const parts: Doc[] = [docText("export " + typeModifier(inner))];
	if (id.importNames.length > 0) {
		const names = specifierDocs(id);
		const commented = commentedSpecifiers(names, id.nameLocations, outer);
		if (commented != null) {
			parts.push(commented);
		} else if (names.length == 1) {
			parts.push(docText("{ "));
			parts.push(names[0]);
			parts.push(docText(" }"));
		} else {
			const nameParts: Doc[] = [docLine()];
			for (let i = 0; i < names.length; i += 1) {
				if (i > 0) nameParts.push(docLine());
				if (i < names.length - 1) {
					nameParts.push(docGroup([names[i], docText(",")]));
				} else {
					nameParts.push(names[i]);
					if (wantsTrailingComma(options, CommaContext.Collection)) {
						nameParts.push(docIfBreak(docText(","), docNil()));
					}
				}
			}
			parts.push(docGroup([docText("{"), docIndent(nameParts), docLine(), docText("}")]));
		}
		parts.push(docText(" from "));
	}
	parts.push(docText(q + id.importSource + q));
	if (options.semi) parts.push(docText(";"));
	return docGroup(parts);
}

function aliasWithInnerComments(node: Node, options: FormatOptions): string {
	const loc = node.location;
	if (loc.endLine == 0) return "";
	const end = makeLoc(loc.endLine, loc.endColumn);
	if (commentsWithin(loc, end).length == 0) return "";
	const text = sourceSpan(options.source, loc.line, loc.column, loc.endLine, loc.endColumn);
	if (text != "") markWithin(loc, end);
	return text;
}

export function printTypeAliasDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeAliasDeclData;
	const verbatim = aliasWithInnerComments(node, options);
	if (verbatim != "") return docText(verbatim);
	const distinct = d.aliasIsDistinct ? "distinct " : "";
	const head = (node.flags.has(NodeFlag.ValueUnion) ? "struct " : "type ") + d.aliasName + genericsFor(options, d.nameLocation, d.aliasName, d.aliasGenericParams);
	if (d.discriminantName != "" && d.discriminantName != null) {
		// Discriminated union: type X<...> = match (disc: Enum) { ... }
		// Use docIndent so the layout engine respects useTabs/tabWidth.
		const arms: Doc[] = [];
		for (let i = 0; i < d.variantKeys.length; i += 1) {
			arms.push(docText(d.variantKeys[i] + " => " + d.variantTypes[i] + ","));
		}
		const armsBlock: Doc[] = [docHardLine()];
		for (let i = 0; i < arms.length; i += 1) {
			if (i > 0) armsBlock.push(docHardLine());
			armsBlock.push(arms[i]);
		}
		const parts: Doc[] = [
			docText(head + " = match (" + d.discriminantName + ": " + d.discriminantType + ") {"),
			docIndent(armsBlock),
			docHardLine(),
			docText("}"),
		];
		if (options.semi) parts.push(docText(";"));
		return docGroup(parts);
	}
	const parts: Doc[] = [docText(head + " = " + distinct + d.aliasType)];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printEnumDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as EnumDeclData;
	const inner = bodyComments(node);
	if (d.enumMembers.length == 0) {
		if (inner.length == 0) return docText("enum " + d.enumName + " {}");
		return boxed("enum " + d.enumName + " {", [danglingBlock(inner)], "}");
	}

	const members: Doc[] = [];
	const lines: int32[] = [];
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		const init = i < d.memberLocations.length
			? writtenInitializer(options.source, d.memberLocations[i].line, d.memberLocations[i].column, d.enumMembers[i])
			: "";
		members.push(docText(d.enumMembers[i] + (init != "" ? " = " + init : "") + ","));
		lines.push(i < d.memberLocations.length ? d.memberLocations[i].line : 0);
	}
	return boxed("enum " + d.enumName + " {", interleave(members, lines, lines, inner), "}");
}

function printStructLikeDecl(node: Node, keyword: string, options: FormatOptions): Doc {
	const d = node.data as InterfaceDeclData;
	const extendsClause = d.interfaceExtends.length > 0 ? " extends " + d.interfaceExtends.join(", ") : "";
	const head = keyword + " " + d.interfaceName + genericsFor(options, d.nameLocation, d.interfaceName, node.typeArg) + extendsClause + (d.nativeName != "" ? nativeFrom(d.nativeName) : "");
	const accessors = keyword == "struct" ? takeStructAccessors() : [];
	let accessorIdx = 0;
	if (d.interfaceFields.length == 0 && accessors.length == 0) {
		const orphans = bodyComments(node);
		return orphans.length == 0 ? docText(head + " {}") : boxed(head + " {", [danglingBlock(orphans)], "}");
	}

	const fieldLocs = node.paramLocations!;
	const inner = bodyComments(node);
	const fields: Doc[] = [];
	const lines: int32[] = [];
	const starts: int32[] = [];
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		const fieldLine = i < fieldLocs.length ? fieldLocs[i].line : 0;
		while (accessorIdx < accessors.length && accessors[accessorIdx].location.line < fieldLine) {
			fields.push(printStructGetter(accessors[accessorIdx], options));
			lines.push(accessors[accessorIdx].location.line);
			starts.push(accessors[accessorIdx].location.line);
			accessorIdx = accessorIdx + 1;
		}
		let field = d.interfaceFields[i];
		const optional = i < fieldLocs.length && writtenOptional(options.source, fieldLocs[i].line, fieldLocs[i].column, field);
		const keptType = optional && writtenTypeAfterOptional(options.source, fieldLocs[i].line, fieldLocs[i].column, field, d.interfaceFieldTypes[i]);
		if (optional) field = field + "?";
		if (d.interfaceFieldTypes[i] != "") {
			field = field + ": " + (optional && !keptType ? unoptionalized(d.interfaceFieldTypes[i]) : d.interfaceFieldTypes[i]);
		}
		if (d.interfaceFieldVisibility != null && i < d.interfaceFieldVisibility.length && d.interfaceFieldVisibility[i] != "") field = d.interfaceFieldVisibility[i] + " " + field;
		const sep = i + 1 < fieldLocs.length && writtenCommaBetween(options.source, fieldLocs[i], fieldLocs[i + 1]) ? "," : ";";
		const lead: Doc[] = [];
		let startLine = fieldLine;
		if (i < d.interfaceFieldDecorators.length) {
			const decorators = d.interfaceFieldDecorators[i];
			let ownLine = false;
			for (const dec of decorators) {
				if (dec.location.line != fieldLine) ownLine = true;
				startLine = Math.min(startLine, dec.location.line) as int32;
			}
			for (const dec of decorators) {
				lead.push(callPrintNode(dec, options));
				lead.push(ownLine ? docHardLine() : docLine());
			}
		}
		lead.push(docText(field + sep));
		fields.push(lead.length > 1 ? docGroup(lead) : lead[0]);
		lines.push(fieldLine);
		starts.push(startLine);
	}
	while (accessorIdx < accessors.length) {
		fields.push(printStructGetter(accessors[accessorIdx], options));
		lines.push(accessors[accessorIdx].location.line);
		starts.push(accessors[accessorIdx].location.line);
		accessorIdx = accessorIdx + 1;
	}
	return boxed(head + " {", interleave(fields, lines, starts, inner), "}");
}

function printStructGetter(getter: Node, options: FormatOptions): Doc {
	const parts: Doc[] = [];
	let fn = getter;
	if (getter.kind == NodeKind.DecoratedDecl) {
		const dd = getter.data as DecoratedDeclData;
		fn = dd.decoratedNode.kind == NodeKind.ExportDecl ? (dd.decoratedNode.data as ExportDeclData).exportedDecl : dd.decoratedNode;
		for (const dec of dd.decorators) {
			parts.push(callPrintNode(dec, options));
			parts.push(dec.location.line != fn.location.line ? docHardLine() : docText(" "));
		}
	}
	const fd = fn.data as FunctionDeclData;
	const ret = fd.fnReturnType != "" ? ": " + fd.fnReturnType : "";
	parts.push(docText("get " + fd.fnName.slice(4, fd.fnName.length) + "()" + ret + " "));
	parts.push(printCollapsibleBody(fd.fnBody, options));
	return withComments(getter, docGroup(parts));
}

export function printInterfaceDecl(node: Node, options: FormatOptions): Doc {
	return printStructLikeDecl(node, "interface", options);
}

export function printStructDecl(node: Node, options: FormatOptions): Doc {
	return printStructLikeDecl(node, "struct", options);
}

export function printClassDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ClassDeclData;
	const generics = genericsFor(options, d.nameLocation, d.className, node.typeArg);
	const parts: Doc[] = [docText((node.flags.has(NodeFlag.Abstract) ? "abstract class " : "class ") + d.className + generics)];
	if (d.classExtends != "") {
		parts.push(docText(" extends " + d.classExtends));
	}
	if (d.classImplements.length > 0) {
		parts.push(docText(" implements " + d.classImplements.join(", ")));
	}
	parts.push(docText(" {"));
	if (d.classBody.length == 0 && danglingOf(node).length > 0) {
		parts.push(docIndent([docHardLine(), docJoin(danglingLines(danglingOf(node)), docHardLine())]));
		parts.push(docHardLine());
	}
	if (d.classBody.length > 0) {
		parts.push(docIndent([docHardLine(), ...printBodyMembers(d.classBody, options)]));
		parts.push(docHardLine());
	}
	parts.push(docText("}"));
	return docGroup(parts);
}

function printBodyMembers(members: Node[], options: FormatOptions): Doc[] {
	const docs: Doc[] = [];
	const starts: int32[] = [];
	for (const m of members) {
		docs.push(printBodyMember(m, options));
		starts.push(startLineOf(m));
	}
	return joinKeepingBlankLines(docs, starts);
}

function printBodyMember(m: Node, options: FormatOptions): Doc {
	if (m.kind == NodeKind.BlockStmt) {
		return withComments(m, docGroup([docText("static "), printCollapsibleBody(m, options)]));
	}
	return callPrintNode(m, options);
}

export function printActorDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ActorDeclData;
	const parts: Doc[] = [docText("actor " + d.actorName)];
	parts.push(docText(" {"));
	if (d.actorBody.length == 0 && danglingOf(node).length > 0) {
		parts.push(docIndent([docHardLine(), docJoin(danglingLines(danglingOf(node)), docHardLine())]));
		parts.push(docHardLine());
	}
	if (d.actorBody.length > 0) {
		parts.push(docIndent([docHardLine(), ...printBodyMembers(d.actorBody, options)]));
		parts.push(docHardLine());
	}
	parts.push(docText("}"));
	return docGroup(parts);
}

export function printExternDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ExternDeclData;
	const keyword = match (d.externKind) {
		ExternKind.Function => "function",
		ExternKind.Class => "class",
		ExternKind.Interface => "interface",
		ExternKind.Struct => "struct",
		ExternKind.Const => "const",
		ExternKind.Var => "var",
		ExternKind.Let => "let",
		ExternKind.Type => "type",
		ExternKind.Enum => "enum",
		ExternKind.Macro => "macro",
		ExternKind.Invalid => "",
	};
	const parts: Doc[] = [docText("extern " + keyword + " " + d.externName)];
	if (d.externType != "") {
		parts.push(docText(": " + d.externType));
	}
	if (d.nativeName != "") {
		parts.push(docText(nativeFrom(d.nativeName)));
	}
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printDecoratedDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as DecoratedDeclData;
	const parts: Doc[] = [];
	const exportFirst = d.decoratedNode.kind == NodeKind.ExportDecl && !d.decoratedNode.flags.has(NodeFlag.ExportDefault)
		&& sourceByteAt(options.source, node.location.line, node.location.column) == "e".code;
	if (exportFirst) {
		parts.push(docText("export "));
		for (const dec of d.decorators) {
			parts.push(callPrintNode(dec, options));
			parts.push(docText(" "));
		}
		parts.push(callPrintNode((d.decoratedNode.data as ExportDeclData).exportedDecl, options));
		return docGroup(parts);
	}
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
		docText("test " + q + escapeForQuote(d.testName, q) + q + " "),
		callPrintNode(d.testBody, options),
	]);
}

// Re-escape a string value for emission inside a quoted literal. The lexer
// unescapes `\"`, `\'`, `\\` etc. on the way in; we must reverse that.
function escapeForQuote(s: string, quote: string): string {
	let out = "";
	// Run-copied for multi-byte UTF-8 safety (see fmt/printer/literals.ms).
	const q = quote.byteAt(0);
	let runStart = 0;
	let i = 0;
	while (i < s.byteLength) {
		const ch = s.byteAt(i);
		const isEsc = ch == "\\".code || ch == q || ch == "\n".code || ch == "\t".code || ch == "\r".code;
		if (isEsc) {
			if (runStart < i) out = out + s.byteSlice(runStart, i);
			if (ch == "\\".code) { out = out + "\\\\"; }
			else if (ch == q) { out = out + "\\" + quote; }
			else { out = out + match (ch) { "\n".code => "\\n", "\t".code => "\\t", _ => "\\r" }; }
			runStart = i + 1;
		}
		i = i + 1;
	}
	if (runStart < s.byteLength) out = out + s.byteSlice(runStart, s.byteLength);
	return out;
}

export function printAssertStmt(node: Node, options: FormatOptions): Doc {
	const d = node.data as AssertStmtData;
	const parts: Doc[] = [
		docText("assert "),
		callPrintNode(d.assertExpr, options),
	];
	if (d.assertMessageExpr != null) {
		parts.push(docText(", "));
		parts.push(callPrintNode(d.assertMessageExpr, options));
	} else if (d.assertMessage.length > 0) {
		// Re-escape: lexer unescapes `\"`, `\n`, etc. — reverse that.
		parts.push(docText(", \"" + escapeForQuote(d.assertMessage, "\"") + "\""));
	}
	parts.push(docText(";"));
	return docGroup(parts);
}

export function printPropertyDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as PropertyDeclData;
	const parts: Doc[] = [];
	if (d.propVisibility != "") parts.push(docText(d.propVisibility + " "));
	if (d.propIsStatic) parts.push(docText("static "));
	if (d.propIsReadonly) parts.push(docText("readonly "));
	if (node.flags.has(NodeFlag.Abstract)) parts.push(docText("abstract "));
	if (node.flags.has(NodeFlag.AutoAccessor)) parts.push(docText("accessor "));
	const optional = writtenOptional(options.source, node.location.line, node.location.column, d.propName);
	const keptType = optional && writtenTypeAfterOptional(options.source, node.location.line, node.location.column, d.propName, d.propType);
	parts.push(docText(optional ? d.propName + "?" : d.propName));
	if (d.propType != "") {
		parts.push(docText(": " + (optional && !keptType ? unoptionalized(d.propType) : d.propType)));
	}
	if (d.propInitializer != null) {
		parts.push(docText(" = "));
		parts.push(callPrintNode(d.propInitializer, options));
	}
	parts.push(docText(";"));
	return docGroup(parts);
}

export function printMacroDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as MacroDeclData;
	const noDefaults: Node[] = [];
	const params = buildParamList(d.macroDeclParams, d.macroDeclParamTypes, noDefaults, options);
	const keyword = node.flags.has(NodeFlag.Converter) ? "converter " : "macro ";
	const parts: Doc[] = [docText(keyword + d.macroDeclName)];
	for (const p of paramListInParens(params, options)) parts.push(p);
	if (d.macroDeclReturnType != "") parts.push(docText(": " + d.macroDeclReturnType));
	parts.push(docText(" "));
	parts.push(callPrintNode(d.macroDeclBody, options));
	return docGroup(parts);
}

export function printConstructorDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ConstructorDeclData;
	const visibility = d.ctorVisibility != "" ? d.ctorVisibility + " " : "";
	const asWritten = headerAsWritten(node, d.ctorBody, options, null);
	if (asWritten != null) return docGroup([docText(visibility), asWritten, printCollapsibleBody(d.ctorBody, options)]);
	const params = buildParamList(d.ctorParams, d.ctorParamTypes, d.ctorDefaults, options, node.paramLocations);
	const parts: Doc[] = [docText(visibility + "constructor")];
	for (const p of paramListInParens(params, options)) parts.push(p);
	parts.push(docText(" "));
	parts.push(printCollapsibleBody(d.ctorBody, options));
	return docGroup(parts);
}

export function printMethodDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as MethodDeclData;
	// methodFlags carries: "async", "generator", "async_generator", "extern",
	// "async_actor", and "gen:T,U" (generics). Decode each.
	const isExtern = flagHas(d.methodFlags, "extern");
	const isAsync = flagHas(d.methodFlags, "async") || flagHas(d.methodFlags, "async_generator") || flagHas(d.methodFlags, "async_actor");
	const isGen = flagHas(d.methodFlags, "generator") || flagHas(d.methodFlags, "async_generator");

	const modifiers = (d.methodVisibility != "" ? d.methodVisibility + " " : "")
		+ (d.methodIsStatic ? "static " : "")
		+ (node.flags.has(NodeFlag.Abstract) ? "abstract " : "")
		+ (isExtern ? "extern " : "")
		+ (isAsync ? "async " : "")
		+ (isGen ? "*" : "");
	const head = modifiers
		+ (node.flags.has(NodeFlag.Accessor) ? d.methodName.slice(0, 3) + " " + d.methodName.slice(4, d.methodName.length) : writtenName(options, d.nameLocation, d.methodName)) + genericsFor(options, d.nameLocation, writtenName(options, d.nameLocation, d.methodName), flagGet(d.methodFlags, "gen"));

	const asWritten = headerAsWritten(node, d.methodBody, options, node.paramLocations);
	if (asWritten != null) return docGroup([docText(modifiers), asWritten, printCollapsibleBody(d.methodBody, options)]);
	const parts: Doc[] = [docText(head)];
	const params = buildParamList(d.methodParams, d.methodParamTypes, d.methodDefaults, options, node.paramLocations);
	const paramComments = paramListComments(node, d.methodBody);
	if (paramComments.length > 0 && node.paramLocations != null) {
		parts.push(commentedList(params, node.paramLocations, paramComments, "(", ")"));
	} else {
		for (const p of paramListInParens(params, options)) parts.push(p);
	}
	if (d.methodReturnType != "") {
		parts.push(docText(": " + d.methodReturnType));
	}
	if (isSynthesized(node, d.methodBody)) {
		if (d.nativeName != "") parts.push(docText(nativeFrom(d.nativeName)));
		parts.push(docText(";"));
		return docGroup(parts);
	}
	parts.push(docText(" "));
	parts.push(printCollapsibleBody(d.methodBody, options));
	return docGroup(parts);
}
