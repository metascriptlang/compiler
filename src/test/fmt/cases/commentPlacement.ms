import { parseSource } from "../../../parser/statements/validation";
import "../../../parser/statements/core"; // side-effect: register sub-parsers
import { lex } from "../../../lexer/lexer";
import { Node } from "../../../ast/node";
import { forEachChild } from "../../../ast/visitor";
import {
	decorateComments,
	Comments,
	SourceComment,
	CommentKind,
	CommentPosition,
	leading,
	trailing,
	dangling,
	markFormatted,
	assertAllFormatted,
} from "../../../compiler/fmt/comments";
import { astShape } from "../roundtrip";

function allNodes(node: Node, out: Node[]): void {
	out.push(node);
	forEachChild(node, (child: Node): void => allNodes(child, out));
}

function ownerOf(comments: Comments, nodes: Node[], c: SourceComment): string {
	const owners: string[] = [];
	for (const n of nodes) {
		for (const x of comments.leading(n)) if (x == c) owners.push("leading " + astShape(n));
		for (const x of comments.trailing(n)) if (x == c) owners.push("trailing " + astShape(n));
		for (const x of comments.dangling(n)) if (x == c) owners.push("dangling " + astShape(n));
	}
	return owners.length == 1 ? owners[0] : owners.length.toString() + " owners";
}

function decorated(source: string, nodes: Node[]): Comments {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error("parse: " + parsed.error);
	const tokens = lex(source);
	if (!tokens.ok) throw new Error("lex: " + tokens.error);
	const placed = decorateComments(parsed.value, tokens.value);
	if (!placed.ok) throw new Error("decorate: " + placed.error);
	allNodes(parsed.value, nodes);
	return placed.value;
}

export function placements(source: string): string[] {
	const nodes: Node[] = [];
	const comments = decorated(source, nodes);
	const out: string[] = [];
	for (const c of comments.all) out.push(c.text + " => " + ownerOf(comments, nodes, c));
	return out;
}

function atEveryDepth(body: string): string[] {
	return [
		body,
		"class C {\n\tm() {\n" + body + "\n\t}\n}",
		"const g = () => {\n" + body + "\n};",
	];
}

function placedAtEveryDepth(body: string, expected: string[]): string {
	for (const source of atEveryDepth(body)) {
		const got = placements(source);
		if (got.join("|") != expected.join("|")) {
			return "in `" + source.replaceAll("\n", "\\n") + "` got [" + got.join(" | ") + "]";
		}
	}
	return "";
}

test "comments: a comment after a call argument's comma trails that argument" {
	const miss = placedAtEveryDepth("f(1, // one\n 2);", ["// one => trailing NumberLiteral[1]"]);
	assert miss == "", miss;
}

test "comments: an own-line comment before a statement leads that statement" {
	const miss = placedAtEveryDepth("a;\n// c\nb;", ["// c => leading ExprStmt(Identifier[b])"]);
	assert miss == "", miss;
}

test "comments: a comment alone in an empty block dangles from the block" {
	const miss = placedAtEveryDepth("{ /* c */ }", ["/* c */ => dangling BlockStmt{}"]);
	assert miss == "", miss;
}

test "comments: an end-of-line comment after the last statement of a block trails that statement" {
	const miss = placedAtEveryDepth(
		"{\n\ta;\n\tb; // c\n}",
		["// c => trailing ExprStmt(Identifier[b])"],
	);
	assert miss == "", miss;
}

test "comments: a comment between an if condition and its block leads the block" {
	const block = "BlockStmt{ExprStmt(Identifier[b])}";
	assert placedAtEveryDepth("if (a) /* c */ {\n\tb;\n}", ["/* c */ => leading " + block]) == "";
	assert placedAtEveryDepth("if (a)\n// c\n{\n\tb;\n}", ["// c => leading " + block]) == "";
}

test "comments: a comment after return leads its argument, or trails a bare return" {
	assert placedAtEveryDepth("return /* c */ 1;", ["/* c */ => leading NumberLiteral[1]"]) == "";
	assert placedAtEveryDepth("return; // c", ["// c => trailing ReturnStmt(null)"]) == "";
}

test "comments: a comment between object properties attaches to a property value" {
	const eol = "const o = {\n\ta: 1, // c\n\tb: 2,\n};";
	const ownLine = "const o = {\n\ta: 1,\n\t// c\n\tb: 2,\n};";
	assert placedAtEveryDepth(eol, ["// c => trailing NumberLiteral[1]"]) == "";
	assert placedAtEveryDepth(ownLine, ["// c => leading NumberLiteral[2]"]) == "";
}

test "comments: a comment inside a type annotation lands on the node that follows the type" {
	const decl = "VariableDecl[Let v:int32](null)";
	const initializer = ["/* c */ => leading NumberLiteral[1]"];
	assert placedAtEveryDepth("let v: /* c */ int32 = 1;", initializer) == "";
	assert placedAtEveryDepth("let v: /* c */ int32;", ["/* c */ => dangling " + decl]) == "";
}

test "comments: an inline block comment trails the operand it touches or leads the next one" {
	assert placedAtEveryDepth("a /* x */ + b;", ["/* x */ => trailing Identifier[a]"]) == "";
	assert placedAtEveryDepth("f(a /* x */, b);", ["/* x */ => trailing Identifier[a]"]) == "";
	assert placedAtEveryDepth("f(a, /* x */ b);", ["/* x */ => leading Identifier[b]"]) == "";
}

test "comments: several comments between two statements split between trailing and leading" {
	const miss = placedAtEveryDepth("a; // one\n// two\nb;", [
		"// one => trailing ExprStmt(Identifier[a])",
		"// two => leading ExprStmt(Identifier[b])",
	]);
	assert miss == "", miss;
}

test "comments: comments at the end of a file trail the last statement" {
	const expected = "// end => trailing ExprStmt(Identifier[a])";
	assert placements("a;\n// end").join("|") == expected;
	assert placements("a; // end").join("|") == expected;
}

test "comments: a comment before the first statement leads it" {
	assert placements("// top\na;").join("|") == "// top => leading ExprStmt(Identifier[a])";
}

test "comments: a file of only a comment dangles it from the program" {
	assert placements("// only\n").join("|") == "// only => dangling Program{}";
}

test "comments: position, kind and line counts come from the source" {
	const nodes: Node[] = [];
	const source = "a; // e\n\n// own\n/* inline */ b; /* same */ c;\n/* two\nlines */\n";
	const comments = decorated(source, nodes);
	const all = comments.all;
	assert all.length == 5;
	assert all[0].position == CommentPosition.EndOfLine && all[0].kind == CommentKind.Line;
	assert all[0].linesBefore == 0 && all[0].linesAfter == 2;
	assert all[1].position == CommentPosition.OwnLine;
	assert all[1].linesBefore == 2 && all[1].linesAfter == 1;
	assert all[2].position == CommentPosition.OwnLine && all[2].kind == CommentKind.InlineBlock;
	assert all[2].linesBefore == 1 && all[2].linesAfter == 0;
	assert all[3].position == CommentPosition.SameLine;
	assert all[3].linesBefore == 0 && all[3].linesAfter == 0;
	assert all[4].kind == CommentKind.Block && all[4].position == CommentPosition.OwnLine;
}

test "comments: a formatted comment is not reported" {
	const nodes: Node[] = [];
	const comments = decorated("a; // x\nb; /* y */\n", nodes);
	assert !assertAllFormatted(comments).ok;
	for (const c of comments.all) c.markFormatted();
	assert assertAllFormatted(comments).ok;
}

test "comments: an unformatted comment is named by line and column" {
	const nodes: Node[] = [];
	const comments = decorated("a; // x\nb; /* y */\n", nodes);
	comments.all[0].markFormatted();
	const r = assertAllFormatted(comments);
	assert !r.ok && r.error.contains("2:4") && !r.error.contains("1:4");
}
