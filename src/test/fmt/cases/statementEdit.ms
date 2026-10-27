import { parseSource } from "../../../parser/statements/validation";
import "../../../parser/statements/core";
import { NodeKind } from "../../../ast/node";
import { defaultFormatOptions } from "../../../compiler/fmt/options";
import { formatRunEdits, rangeStatements, StatementRun } from "../../../compiler/fmt/edit";

function runAt(source: string, line: int32, column: int32): StatementRun | null {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error(parsed.error);
	const run = rangeStatements(parsed.value, { line, column }, { line, column });
	if (!run.ok) throw new Error(run.error);
	return run.value;
}

function reformatAt(source: string, line: int32, column: int32): string {
	const run = runAt(source, line, column);
	if (run == null) return "NO STATEMENT";
	const edits = formatRunEdits(run, source, defaultFormatOptions());
	if (!edits.ok) return "FMT ERROR: " + edits.error;
	let result = source;
	for (let i = edits.value.length - 1; i >= 0; i -= 1) {
		const e = edits.value[i];
		result = result.byteSlice(0, e.start) + e.newText + result.byteSlice(e.end, result.byteLength);
	}
	return result;
}

function stmtKindAt(source: string, line: int32, column: int32): string {
	const run = runAt(source, line, column);
	if (run == null) return "none";
	return NodeKind[run.first.kind];
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
