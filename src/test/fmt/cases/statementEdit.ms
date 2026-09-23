import { parseSource } from "../../../parser/statements/validation";
import "../../../parser/statements/core";
import { resetAllSideChannels } from "../../../parser/context";
import { NodeKind } from "../../../ast/node";
import { defaultFormatOptions } from "../../../compiler/fmt/options";
import { formatStatementEdit, innermostStatement, applyEdit } from "../../../compiler/fmt/edit";

function reformatAt(source: string, line: int32, column: int32): string {
	resetAllSideChannels();
	const parsed = parseSource(source);
	if (!parsed.ok) return "PARSE ERROR: " + parsed.error;
	const stmt = innermostStatement(parsed.value, { line, column }, { line, column });
	if (stmt == null) return "NO STATEMENT";
	const edit = formatStatementEdit(stmt, source, defaultFormatOptions());
	if (!edit.ok) return "FMT ERROR: " + edit.error;
	return applyEdit(source, edit.value);
}

function stmtKindAt(source: string, line: int32, column: int32): string {
	resetAllSideChannels();
	const parsed = parseSource(source);
	if (!parsed.ok) return "PARSE ERROR";
	const stmt = innermostStatement(parsed.value, { line, column }, { line, column });
	if (stmt == null) return "none";
	return NodeKind[stmt.kind];
}

const MIXED = "const xs = [\n\t1,\n\t2,\n];\nfunction f(): void {\n\tlet   x=1;\n\tconst y = [3,\n\t\t4];\n}\n";

test "fmt edit: only the statement under the cursor changes" {
	assert reformatAt(MIXED, 6, 3) == "const xs = [\n\t1,\n\t2,\n];\nfunction f(): void {\n\tlet x = 1;\n\tconst y = [3,\n\t\t4];\n}\n";
}

test "fmt edit: the innermost statement wins over its enclosing declaration" {
	assert stmtKindAt(MIXED, 6, 3) == "VariableDecl";
	assert stmtKindAt(MIXED, 5, 3) == "FunctionDecl";
	assert stmtKindAt(MIXED, 2, 2) == "VariableDecl";
}

const LONG = "function f(): Node {\n\treturn <panel title=\"a fairly long title value\" subtitle=\"another long value\" onClose={handleCloseOfThePanel}>body</panel>;\n}\n";

test "fmt edit: continuation lines keep the statement's tab indentation" {
	const out = reformatAt(LONG, 2, 3);
	assert out.contains("\n\t  title=\"a fairly long title value\"\n");
	assert out.contains("\n\t>body</panel>;\n}\n");
}

const JSX_TEXT = "function f(): Node {\n\treturn <a>\n\t\ttext {v}\n\t</a>;\n}\n";

test "fmt edit: JSX text inside an indented statement is left verbatim" {
	assert reformatAt(JSX_TEXT, 2, 3) == JSX_TEXT;
}

const COMMENTS = "const a = 1;\n// lead\nlet   b=2; // tail\nconst c = 3;\n";

test "fmt edit: the statement's own comments are rewritten once, not duplicated" {
	assert reformatAt(COMMENTS, 3, 3) == "const a = 1;\n// lead\nlet b = 2; // tail\nconst c = 3;\n";
}

test "fmt edit: a position outside every statement finds none" {
	assert stmtKindAt("const a = 1;\n\n", 2, 1) == "none";
}
