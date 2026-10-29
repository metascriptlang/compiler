// Type printer: a type annotation printed from its parsed tree, falling back to its captured text.
// The tree drops some syntax (keyof, typeof, tuples, indexed access, optional markers), so a structural
// print is kept only when its tokens equal the captured text's.

import {
	Node, NodeKind, IdentifierData, MemberExprData, TypeUnionData, TypeIntersectionData, TypeArrayData,
	TypeGenericData, TypeFunctionData, TypeObjectData, makeLoc,
} from "../../../ast/node";
import { FormatOptions, CommaContext, wantsTrailingComma } from "../options";
import {
	Doc, DocKind, docNil, docText, docGroup, docGroupBreak, docIndent, docLine, docSoftLine, docIfBreak,
} from "../doc";
import { commentsWithin } from "./commentDocs";
import { sourceSpan, sourceByteAt, blankLineBefore, normalizeStringToken } from "./literals";

enum TypeParent {
	Annotation,
	TypeArgument,
	Element,
}

const keywordTypes = [
	"any", "unknown", "never", "void", "null", "undefined", "number", "string", "boolean", "bigint",
	"symbol", "object", "this",
];

function isReference(node: Node): boolean {
	return match (node.kind) {
		NodeKind.MemberExpr | NodeKind.TypeGeneric => true,
		NodeKind.Identifier => {
			const name = (node.data as IdentifierData).name;
			return !keywordTypes.includes(name) && !isLiteralName(name);
		},
		_ => false,
	};
}

function isLiteralName(name: string): boolean {
	if (name == "true" || name == "false") return true;
	if (name == "") return false;
	const first = name.byteAt(0);
	return first == "\"".code || first == "'".code || first == "-".code || (first >= "0".code && first <= "9".code);
}

function isSimple(node: Node): boolean {
	return node.kind == NodeKind.Identifier || node.kind == NodeKind.MemberExpr;
}

function isVoidOrNull(node: Node): boolean {
	if (node.kind != NodeKind.Identifier) return false;
	const name = (node.data as IdentifierData).name;
	return name == "void" || name == "null";
}

function unionMembers(node: Node): Node[] {
	return (node.data as TypeUnionData).typExprMembers;
}

function shouldHug(node: Node): boolean {
	if (isSimple(node) || node.kind == NodeKind.TypeObject) return true;
	if (node.kind != NodeKind.TypeUnion) return false;
	const members = unionMembers(node);
	if (members.length == 1) return true;
	let hasObject = false;
	let voids = 0;
	for (const m of members) {
		if (m.kind == NodeKind.TypeObject || isReference(m)) hasObject = true;
		if (isVoidOrNull(m)) voids += 1;
	}
	return voids == members.length - 1 && hasObject;
}

function needsParens(node: Node, parent: TypeParent): boolean {
	if (parent != TypeParent.Element) return false;
	return node.kind == NodeKind.TypeUnion || node.kind == NodeKind.TypeIntersection || node.kind == NodeKind.TypeFunction;
}

let unsupported = false;

function leafText(node: Node, options: FormatOptions): string {
	const name = (node.data as IdentifierData).name;
	if (node.location.endLine == 0) return name;
	const written = sourceSpan(options.source, node.location.line, node.location.column, node.location.endLine, node.location.endColumn);
	if (written == "") return name;
	const first = written.byteAt(0);
	if (first == "\"".code || first == "'".code) return normalizeStringToken(written, options.singleQuote);
	return written;
}

function nameText(node: Node, options: FormatOptions): string {
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		return nameText(d.object, options) + "." + d.property;
	}
	return leafText(node, options);
}

function member(node: Node, parent: TypeParent, options: FormatOptions): Doc {
	const doc = printType(node, parent, options);
	return needsParens(node, parent) ? docGroup([docText("("), doc, docText(")")]) : doc;
}

function printUnion(node: Node, parent: TypeParent, options: FormatOptions): Doc {
	const members = unionMembers(node);
	if (shouldHug(node)) {
		const parts: Doc[] = [];
		for (let i = 0; i < members.length; i += 1) {
			if (i > 0) parts.push(docText(" | "));
			parts.push(member(members[i], TypeParent.Element, options));
		}
		return docGroup(parts);
	}
	const indented = parent != TypeParent.TypeArgument;
	const body: Doc[] = [];
	if (indented) body.push(docIfBreak(docLine(), docNil()));
	body.push(docIfBreak(docText("| "), docNil()));
	for (let i = 0; i < members.length; i += 1) {
		if (i > 0) {
			body.push(docLine());
			body.push(docText("| "));
		}
		body.push(docIndent([member(members[i], TypeParent.Element, options)]));
	}
	if (parent == TypeParent.Element) return docGroup([docIndent(body), docSoftLine()]);
	return docGroup(indented ? [docIndent(body)] : body);
}

function isObjectLike(node: Node): boolean {
	return node.kind == NodeKind.TypeObject;
}

function printIntersection(node: Node, options: FormatOptions): Doc {
	const members = (node.data as TypeIntersectionData).typExprMembers;
	const parts: Doc[] = [];
	let prevObject = false;
	let chainIndented = false;
	for (let i = 0; i < members.length; i += 1) {
		const current = isObjectLike(members[i]);
		const doc = member(members[i], TypeParent.Element, options);
		if (i == 0) {
			parts.push(doc);
		} else if (!prevObject && !current) {
			parts.push(docIndent([docLine(), doc]));
		} else {
			parts.push(docText(" "));
			if (!prevObject || !current) chainIndented = i > 1;
			parts.push(chainIndented ? docIndent([doc]) : doc);
		}
		if (i < members.length - 1) parts.push(docText(" &"));
		prevObject = current;
	}
	return docGroup(parts);
}

function printList(items: Doc[], open: string, close: string, trailing: boolean): Doc {
	if (items.length == 0) return docText(open + close);
	const body: Doc[] = [docSoftLine()];
	for (let i = 0; i < items.length; i += 1) {
		if (i > 0) body.push(docLine());
		body.push(items[i]);
		if (i < items.length - 1) body.push(docText(","));
	}
	if (trailing) body.push(docIfBreak(docText(","), docNil()));
	return docGroup([docText(open), docIndent(body), docSoftLine(), docText(close)]);
}

function printTypeArguments(args: Node[], options: FormatOptions): Doc {
	if (args.length == 1) {
		const only = args[0];
		const isNull = only.kind == NodeKind.Identifier && (only.data as IdentifierData).name == "null";
		if (isNull || shouldHug(only)) return docGroup([docText("<"), printType(only, TypeParent.TypeArgument, options), docText(">")]);
	}
	const items: Doc[] = [];
	for (const arg of args) items.push(printType(arg, TypeParent.TypeArgument, options));
	return printList(items, "<", ">", false);
}

function printFunction(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeFunctionData;
	const items: Doc[] = [];
	for (let i = 0; i < d.typExprParams.length; i += 1) {
		const type = printType(d.typExprParams[i], TypeParent.Annotation, options);
		items.push(d.typExprParamNames[i] == "" ? type : docGroup([docText(d.typExprParamNames[i] + ": "), type]));
	}
	return docGroup([
		printList(items, "(", ")", wantsTrailingComma(options, CommaContext.Params)),
		docText(" => "),
		printType(d.typExprReturn, TypeParent.Annotation, options),
	]);
}

function openBraceEndsLine(node: Node, options: FormatOptions): boolean {
	let column = node.location.column + 1;
	while (true) {
		const byte = sourceByteAt(options.source, node.location.line, column);
		if (byte == " ".code || byte == "\t".code || byte == "\r".code) {
			column += 1;
			continue;
		}
		return byte == "\n".code;
	}
}

function printObject(node: Node, options: FormatOptions): Doc {
	const d = node.data as TypeObjectData;
	if (d.typExprIndexKey != null) {
		unsupported = true;
		return docNil();
	}
	const count = d.typExprFieldNames.length;
	if (count == 0) return docText("{}");
	const locs = node.paramLocations!;
	const body: Doc[] = [docLine()];
	for (let i = 0; i < count; i += 1) {
		if (i > 0) {
			body.push(docLine());
			if (i < locs.length && blankLineBefore(locs[i].line)) body.push(docSoftLine());
		}
		const optional = d.typExprOptionalFields.includes(d.typExprFieldNames[i]) ? "?" : "";
		const field = docGroup([docText(d.typExprFieldNames[i] + optional + ": "), printType(d.typExprFieldTypes[i], TypeParent.Annotation, options)]);
		body.push(field);
		body.push(i < count - 1 ? docText(";") : docIfBreak(docText(";"), docNil()));
	}
	const parts: Doc[] = [docText("{"), docIndent(body), docLine(), docText("}")];
	return openBraceEndsLine(node, options) ? docGroupBreak(parts) : docGroup(parts);
}

function printType(node: Node, parent: TypeParent, options: FormatOptions): Doc {
	return match (node.kind) {
		NodeKind.Identifier | NodeKind.MemberExpr => docText(nameText(node, options)),
		NodeKind.TypeUnion => printUnion(node, parent, options),
		NodeKind.TypeIntersection => printIntersection(node, options),
		NodeKind.TypeArray => {
			const d = node.data as TypeArrayData;
			const size = d.typExprSize >= 0 ? d.typExprSize.toString() : "";
			return docGroup([member(d.typExprElement, TypeParent.Element, options), docText("[" + size + "]")]);
		},
		NodeKind.TypeGeneric => {
			const d = node.data as TypeGenericData;
			return docGroup([printType(d.typExprBase, TypeParent.Element, options), printTypeArguments(d.typExprArgs, options)]);
		},
		NodeKind.TypeFunction => printFunction(node, options),
		NodeKind.TypeObject => printObject(node, options),
		_ => {
			throw new Error("internal: type printer has no case for node kind " + node.kind.toString());
		},
	};
}

function flat(doc: Doc): string {
	return match (doc.kind) {
		DocKind.Nil | DocKind.Line | DocKind.HardLine | DocKind.BreakParent => "",
		DocKind.Text | DocKind.SourceText => (doc.data as { text: string }).text,
		DocKind.IfBreak => flat((doc.data as { broken: Doc, flat: Doc }).flat),
		DocKind.Group | DocKind.Indent | DocKind.LineSuffix | DocKind.IndentIfGroupBreaks | DocKind.Fill => {
			let out = "";
			for (const child of (doc.data as { children: Doc[] }).children) out += flat(child);
			return out;
		},
		DocKind.BestFitting => {
			throw new Error("internal: a type doc has no best-fitting choice");
		},
	};
}

// The tokens of a type with spacing, separators and quote style removed.
function signature(text: string): string {
	let out = "";
	for (let i = 0; i < text.byteLength; i += 1) {
		const c = text.byteAt(i);
		if (c == " ".code || c == "\t".code || c == "\n".code || c == "\r".code) continue;
		const closes = c == ")".code || c == "}".code || c == ">".code || c == "]".code;
		if (closes && out.endsWith(",")) out = out.byteSlice(0, out.byteLength - 1);
		out += c == "'".code ? "\"" : c == ";".code ? "," : text.byteSlice(i, i + 1);
	}
	if (out.endsWith(",")) out = out.byteSlice(0, out.byteLength - 1);
	if (out.startsWith("|") || out.startsWith("&")) return out.byteSlice(1, out.byteLength);
	return out;
}

// The type as its tree prints it, or null when the tree is missing, lacks syntax the text has, or holds a comment.
export function structuralType(expr: Node | null, text: string, options: FormatOptions): Doc | null {
	if (expr == null || expr.location.endLine == 0 || options.source == "") return null;
	const from = makeLoc(expr.location.line, expr.location.column);
	if (commentsWithin(from, makeLoc(expr.location.endLine, expr.location.endColumn)).length > 0) return null;
	unsupported = false;
	const doc = printType(expr, TypeParent.Annotation, options);
	return !unsupported && signature(flat(doc)) == signature(text) ? doc : null;
}

export function printTypeAnnotation(expr: Node | null, text: string, options: FormatOptions): Doc {
	const doc = structuralType(expr, text, options);
	return doc != null ? doc : docText(text);
}

export function isObjectTypeAnnotation(expr: Node | null, text: string, options: FormatOptions): boolean {
	return expr != null && expr.kind == NodeKind.TypeObject && structuralType(expr, text, options) != null;
}
