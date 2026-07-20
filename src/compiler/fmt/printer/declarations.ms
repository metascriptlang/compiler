// Declaration Printers — class, interface, enum, import, export, etc.

import {
	Node, NodeKind, NodeFlag,
	ImportDeclData, ExportDeclData,
	ClassDeclData, ActorDeclData, InterfaceDeclData, EnumDeclData, TypeAliasDeclData,
	ExternDeclData, DecoratedDeclData, TestDeclData, AssertStmtData,
	PropertyDeclData, MethodDeclData, ConstructorDeclData, MacroDeclData,
} from "../../../ast/node";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import {
	Doc, docText, docGroup, docIndent, docLineSuffix,
	docLine, docHardLine, docIfBreak, docNil, docJoin,
} from "../doc";
import { Token } from "../../../lexer/token";
import { getGenericDecl } from "../../../parser/context";
import { callPrintNode } from "./callbacks";
import { flagHas, flagGet, buildParamList, paramListInParens, wrapGenerics } from "./statements";

export function printImportDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ImportDeclData;
	// Namespace import: `import * as M from "..."` — single `*` specifier with alias.
	if (d.importNames.length === 1 && d.importNames[0] === "*") {
		let q = "\"";
		if (options.singleQuote) q = "'";
		const alias = d.importAliases[0];
		const head = alias !== "" && alias !== "*" ? "import * as " + alias + " from " : "import * from ";
		const tail = options.semi ? ";" : "";
		return docGroup([docText(head + q + d.importSource + q + tail)]);
	}
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
	const isDefault = (node.flags & NodeFlag.ExportDefault) !== 0;
	// Re-export form: `export { ... } from "..."` — the exportedDecl is an
	// ImportDecl-shaped node. Inlining `printImportDecl` here would emit a
	// stray `import` keyword (`export import { ... } from ...`), so we
	// build the re-export form directly.
	if (!isDefault && d.exportedDecl !== null && d.exportedDecl.kind === NodeKind.ImportDecl) {
		return printReExport(d.exportedDecl, options);
	}
	// Forward inner-body comments to the inner decl so its printer can
	// pair them with members/fields. The parser attaches body comments to
	// the OUTER ExportDecl (the wrapping node), but the inner printer
	// (printEnumDecl, printStructLikeDecl, etc.) is what needs them.
	if (d.exportedDecl !== null) {
		const innerStart = d.exportedDecl.location.line;
		const remaining: Token[] = [];
		for (const c of node.comments) {
			if (c.line >= innerStart) {
				d.exportedDecl.comments.push(c);
			} else {
				remaining.push(c);
			}
		}
		node.comments = remaining;
	}
	const prefix = isDefault ? "export default " : "export ";
	return docGroup([docText(prefix), callPrintNode(d.exportedDecl, options)]);
}

function printReExport(inner: Node, options: FormatOptions): Doc {
	const id = inner.data as ImportDeclData;
	let q = "\"";
	if (options.singleQuote) q = "'";
	// Star re-export: `export * from "..."` — single `*` specifier (no alias).
	if (id.importNames.length === 1 && id.importNames[0] === "*") {
		const alias = id.importAliases[0];
		const head = alias !== "" && alias !== "*" ? "export * as " + alias + " from " : "export * from ";
		const tail = options.semi ? ";" : "";
		return docGroup([docText(head + q + id.importSource + q + tail)]);
	}
	const parts: Doc[] = [docText("export ")];
	if (id.importNames.length > 0) {
		const names: Doc[] = [];
		for (let i = 0; i < id.importNames.length; i += 1) {
			if (id.importAliases[i] !== "" && id.importAliases[i] !== id.importNames[i]) {
				names.push(docText(id.importNames[i] + " as " + id.importAliases[i]));
			} else {
				names.push(docText(id.importNames[i]));
			}
		}
		if (names.length === 1) {
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

export function printTypeAliasDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeAliasDeclData;
	const distinct = d.aliasIsDistinct ? "distinct " : "";
	const head = distinct + "type " + d.aliasName + wrapGenerics(d.aliasGenericParams);
	if (d.discriminantName !== "" && d.discriminantName !== null) {
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
	const parts: Doc[] = [docText(head + " = " + d.aliasType)];
	if (options.semi) {
		parts.push(docText(";"));
	}
	return docGroup(parts);
}

export function printEnumDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as EnumDeclData;
	if (d.enumMembers.length === 0) return docText("enum " + d.enumName + " {}");

	// Trailing comments on individual members are stored on the EnumDecl
	// node (parser doesn't have per-member nodes). Pair them with members
	// by source line — same trick as printStructLikeDecl.
	const inline: Token[] = [];
	const remaining: Token[] = [];
	for (const c of node.comments) {
		if (c.line > node.location.line) inline.push(c);
		else remaining.push(c);
	}
	node.comments = remaining;

	const members: Doc[] = [];
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		const memberLine = i < d.memberLocations.length ? d.memberLocations[i].line : 0;
		const baseText = d.enumMembers[i] + ",";
		// Find a comment whose line matches this member.
		let attached: Token = null as unknown as Token;
		for (let j = 0; j < inline.length; j += 1) {
			if (inline[j] !== null && inline[j].line === memberLine) {
				attached = inline[j];
				inline[j] = null as unknown as Token;
				break;
			}
		}
		if (attached !== null) {
			members.push(docGroup([
				docText(baseText),
				docLineSuffix([docText(" " + attached.value)]),
			]));
		} else {
			members.push(docText(baseText));
		}
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
	const generics = wrapGenerics(getGenericDecl(d.interfaceName));
	if (d.interfaceFields.length === 0) return docText(keyword + " " + d.interfaceName + generics + " {}");

	// Field source positions are stored on node.paramLocations
	// (parser repurposes that slot — see declaration.ms parseInterfaceLikeDecl).
	// Pair body comments to fields by line number — same trick as printEnumDecl.
	// Comments that don't match any field's line are kept on node.comments and
	// rendered as standalone lines (between fields, after the body) by the
	// dedicated standalone-comment loop below.
	const fieldLocs = node.paramLocations;
	const inline: Token[] = [];
	const remaining: Token[] = [];
	const standalone: Token[] = [];
	for (const comment of node.comments) {
		if (comment.line > node.location.line) {
			// Body comment: try to match a field by line.
			let matched = false;
			for (let i = 0; i < d.interfaceFields.length; i += 1) {
				const fl = i < fieldLocs.length ? fieldLocs[i].line : 0;
				if (fl === comment.line) {
					inline.push(comment);
					matched = true;
					break;
				}
			}
			if (!matched) standalone.push(comment);
		} else {
			remaining.push(comment);
		}
	}
	node.comments = remaining;

	const fields: Doc[] = [];
	let standaloneIdx = 0;
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		const fieldLine = i < fieldLocs.length ? fieldLocs[i].line : 0;
		// Emit any standalone comments that appear BEFORE this field's line.
		while (standaloneIdx < standalone.length && standalone[standaloneIdx].line < fieldLine) {
			fields.push(docText(standalone[standaloneIdx].value));
			standaloneIdx = standaloneIdx + 1;
		}
		let field = d.interfaceFields[i];
		if (d.interfaceFieldTypes[i] !== "") {
			field = field + ": " + d.interfaceFieldTypes[i];
		}
		// Find a trailing comment for this field.
		let attached: Token = null as unknown as Token;
		for (let j = 0; j < inline.length; j += 1) {
			if (inline[j] !== null && inline[j].line === fieldLine) {
				attached = inline[j];
				inline[j] = null as unknown as Token;
				break;
			}
		}
		if (attached !== null) {
			fields.push(docGroup([
				docText(field + ";"),
				docLineSuffix([docText(" " + attached.value)]),
			]));
		} else {
			fields.push(docText(field + ";"));
		}
	}
	// Any standalone comments after the last field — emit at end of body.
	while (standaloneIdx < standalone.length) {
		fields.push(docText(standalone[standaloneIdx].value));
		standaloneIdx = standaloneIdx + 1;
	}
	return docGroup([
		docText(keyword + " " + d.interfaceName + generics + " {"),
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
	const generics = wrapGenerics(getGenericDecl(d.className));
	const parts: Doc[] = [docText("class " + d.className + generics)];
	if (d.classExtends !== "") {
		parts.push(docText(" extends " + d.classExtends));
	}
	parts.push(docText(" {"));
	if (d.classBody.length > 0) {
		// Body comments are attached to the ClassDecl node (not to
		// individual members). Distribute them: each member with
		// matching line gets the comment as a trailing one; comments
		// without a line match become standalone lines between members.
		distributeBodyComments(node, d.classBody);
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

// Move body comments from `containerNode` onto the matching child node
// (by line), so each child's printNode wrapper can render them. Comments
// that don't match any child are kept on containerNode as "below"
// comments — they'll be emitted after the closing brace by the wrapper.
// This is the right behavior for class/actor bodies where members are
// real Nodes (each carrying its own location and comment list).
function distributeBodyComments(containerNode: Node, children: Node[]): void {
	if (containerNode.comments.length === 0) return;
	const remaining: Token[] = [];
	for (const c of containerNode.comments) {
		if (c.line <= containerNode.location.line) {
			remaining.push(c);
			continue;
		}
		// Find a child whose line matches.
		let attached = false;
		for (let i = 0; i < children.length; i += 1) {
			if (children[i].location.line === c.line) {
				children[i].comments.push(c);
				attached = true;
				break;
			}
		}
		if (!attached) {
			// Standalone comment — attach to next child (so it appears
			// as a "leading" comment of that child).
			let assigned = false;
			for (let i = 0; i < children.length; i += 1) {
				if (children[i].location.line > c.line) {
					children[i].comments.push(c);
					assigned = true;
					break;
				}
			}
			if (!assigned) remaining.push(c);
		}
	}
	containerNode.comments = remaining;
}

export function printActorDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ActorDeclData;
	const parts: Doc[] = [docText("actor " + d.actorName)];
	parts.push(docText(" {"));
	if (d.actorBody.length > 0) {
		distributeBodyComments(node, d.actorBody);
		const members: Doc[] = [];
		for (const m of d.actorBody) {
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
		docText("test " + q + escapeForQuote(d.testName, q) + q + " "),
		callPrintNode(d.testBody, options),
	]);
}

// Re-escape a string value for emission inside a quoted literal. The lexer
// unescapes `\"`, `\'`, `\\` etc. on the way in; we must reverse that.
function escapeForQuote(s: string, quote: string): string {
	let out = "";
	// Run-copied for multi-byte UTF-8 safety on the Bun host (see fmt/printer/literals.ms).
	const q = quote.byteAt(0);
	let runStart = 0;
	let i = 0;
	while (i < s.byteLength) {
		const ch = s.byteAt(i);
		const isEsc = ch === "\\".code || ch === q || ch === "\n".code || ch === "\t".code || ch === "\r".code;
		if (isEsc) {
			if (runStart < i) out = out + s.byteSlice(runStart, i);
			if (ch === "\\".code) { out = out + "\\\\"; }
			else if (ch === q) { out = out + "\\" + quote; }
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
	if (d.assertMessageExpr !== null) {
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
	if (d.propVisibility !== "") parts.push(docText(d.propVisibility + " "));
	if (d.propIsStatic) parts.push(docText("static "));
	if (d.propIsReadonly) parts.push(docText("readonly "));
	parts.push(docText(d.propName));
	if (d.propType !== "") {
		parts.push(docText(": " + d.propType));
	}
	if (d.propInitializer !== null) {
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
	const parts: Doc[] = [docText("macro " + d.macroDeclName)];
	for (const p of paramListInParens(params, options)) parts.push(p);
	parts.push(docText(" "));
	parts.push(callPrintNode(d.macroDeclBody, options));
	return docGroup(parts);
}

export function printConstructorDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as ConstructorDeclData;
	const params = buildParamList(d.ctorParams, d.ctorParamTypes, d.ctorDefaults, options);
	const parts: Doc[] = [docText("constructor")];
	for (const p of paramListInParens(params, options)) parts.push(p);
	parts.push(docText(" "));
	parts.push(callPrintNode(d.ctorBody, options));
	return docGroup(parts);
}

export function printMethodDecl(node: Node, options: FormatOptions): Doc {
	const d = node.data as MethodDeclData;
	// methodFlags carries: "async", "generator", "async_generator", "extern",
	// "async_actor", and "gen:T,U" (generics). Decode each.
	const isExtern = flagHas(d.methodFlags, "extern");
	const isAsync = flagHas(d.methodFlags, "async") || flagHas(d.methodFlags, "async_generator") || flagHas(d.methodFlags, "async_actor");
	const isGen = flagHas(d.methodFlags, "generator") || flagHas(d.methodFlags, "async_generator");

	const head = (d.methodVisibility !== "" ? d.methodVisibility + " " : "")
		+ (d.methodIsStatic ? "static " : "")
		+ (isExtern ? "extern " : "")
		+ (isAsync ? "async " : "")
		+ (isGen ? "*" : "")
		+ d.methodName + wrapGenerics(flagGet(d.methodFlags, "gen"));

	const parts: Doc[] = [docText(head)];
	const params = buildParamList(d.methodParams, d.methodParamTypes, d.methodDefaults, options);
	for (const p of paramListInParens(params, options)) parts.push(p);
	if (d.methodReturnType !== "") {
		parts.push(docText(": " + d.methodReturnType));
	}
	parts.push(docText(" "));
	parts.push(callPrintNode(d.methodBody, options));
	return docGroup(parts);
}
