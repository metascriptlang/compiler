// The branches of a `when` chain.
//
// Symptom:    `msc fmt` left every statement inside `when (...) { ... }` exactly as
//             written: a long signature inside `when (!testBuild)` stayed on one line
//             while the same signature outside it broke.
// Root cause: the compile parse keeps only the picked branch, so fmt printed the
//             whole chain as source text to avoid losing the others.
// Fix:        the fmt parse (parseForFormat) keeps every branch as an IfStmt chain
//             flagged WhenKept; the printer writes each head as written and formats
//             each body. The compile parse is unchanged.

import { assertFmtLossless, assertFmtPreservesAst, assertFmtIdempotent, fmt, astShape } from "../roundtrip";
import { parseSource, parseForFormat } from "../../../parser/statements/validation";
import { Node, NodeFlag, ProgramData } from "../../../ast/node";
import { forEachChild } from "../../../ast/visitor";
import { formatNode } from "../../../compiler/fmt/printer/index";
import { defaultFormatOptions } from "../../../compiler/fmt/options";

const LONG = "function inner(first: int32, second: int32, third: int32, fourth: int32): int32 {\n\treturn first + fourth;\n}\n";

function indented(text: string): string {
	return text.split("\n").map((line: string): string => line.length > 0 ? "\t" + line : line).join("\n");
}

function wrapped(head: string, body: string): string {
	return head + " {\n" + indented(body) + "}\n";
}

test "fmt: a body inside an unpicked when branch formats like the same body outside" {
	const outside = fmt(LONG);
	assert outside.contains("inner(\n"), outside;
	const inside = fmt(wrapped("when (!testBuild)", LONG));
	assert inside == wrapped("when (!testBuild)", outside), inside;
}

test "fmt: every branch of when, else when and else is formatted" {
	const src = "when (neverDefinedA) {\n" + indented(LONG) + "} else when (!neverDefinedB) {\n" + indented(LONG) + "} else {\n" + indented(LONG) + "}\n";
	const out = fmt(src);
	assert out.split("inner(\n").length == 4, out;
	assert assertFmtLossless(src);
	assert assertFmtPreservesAst(src);
	assert assertFmtIdempotent(src);
}

test "fmt: a when nested in a picked branch and in an unpicked branch" {
	const nested = "when (neverDefinedC) {\n\tconst a   =  1;\n} else {\n\tconst b   =  2;\n}\n";
	const src = "when (!neverDefinedA) {\n" + indented(nested) + "} else {\n" + indented(nested) + "}\n";
	const out = fmt(src);
	assert out.split("const a = 1;").length == 3 && out.split("const b = 2;").length == 3, out;
	assert assertFmtLossless(src);
	assert assertFmtPreservesAst(src);
	assert assertFmtIdempotent(src);
}

test "fmt: comments inside an unpicked branch stay in place" {
	const src = "when (neverDefinedA) {\n\t// only on that target\n\tconst a = 1; // trailing\n} else {\n\tconst b = 2;\n}\n";
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
	assert fmt(src).contains("\t// only on that target\n\tconst a = 1; // trailing\n"), fmt(src);
}

test "fmt: a branch holding code only another target compiles is formatted" {
	const src = "when (neverDefinedJsTarget) {\n\tconst el   = document.getElementById(\"root\");\n\twindow.addEventListener(\"resize\", (e: Event): void => { console.log(e); });\n}\n";
	assert fmt(src).contains("const el = document.getElementById(\"root\");"), fmt(src);
	assert assertFmtLossless(src);
	assert assertFmtIdempotent(src);
}

test "fmt: a when whose condition waits for a type parameter keeps every branch" {
	const src = "function size<T>(): int32 {\n\twhen (isPod<T>()) {\n\t\treturn   1;\n\t} else {\n\t\treturn   2;\n\t}\n}\n";
	const out = fmt(src);
	assert out.contains("when (isPod<T>()) {\n\t\treturn 1;\n\t} else {\n\t\treturn 2;\n\t}"), out;
	assert assertFmtIdempotent(src);
}

function anyKept(node: Node): boolean {
	if (node.flags.has(NodeFlag.WhenKept)) return true;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && anyKept(child)) found = true;
	});
	return found;
}

function shapeOf(src: string): string {
	const parsed = parseSource(src);
	if (!parsed.ok) return "PARSE ERROR: " + parsed.error;
	if (anyKept(parsed.value)) return "KEPT IN A COMPILE PARSE: " + src;
	return astShape(parsed.value);
}

test "parse: a compile parse still keeps only the picked when branch" {
	assert shapeOf("when (neverDefinedA) {\n\tconst a = 1;\n} else when (!neverDefinedB) {\n\tconst b = 2;\n} else {\n\tconst c = 3;\n}\nconst d = 4;\n")
		== shapeOf("const b = 2;\nconst d = 4;\n");
	assert shapeOf("when (neverDefinedA) {\n\tconst a = 1;\n}\nconst d = 4;\n") == shapeOf("const d = 4;\n");
	assert shapeOf("function f(): int32 {\n\twhen (!neverDefinedA) {\n\t\twhen (neverDefinedB) {\n\t\t\treturn 1;\n\t\t}\n\t\treturn 2;\n\t}\n\treturn 3;\n}\n")
		== shapeOf("function f(): int32 {\n\treturn 2;\n\treturn 3;\n}\n");
	const deferred = parseSource("function size<T>(): int32 {\n\twhen (isPod<T>()) {\n\t\treturn 1;\n\t}\n\treturn 2;\n}\n");
	assert deferred.ok && !anyKept(deferred.value);
}

test "parse: the fmt parse keeps one node per chain and the compile parse none" {
	const src = "when (neverDefinedA) {\n\tconst a = 1;\n} else {\n\tconst b = 2;\n}\n";
	const kept = parseForFormat(src);
	assert kept.ok;
	if (kept.ok) {
		const stmts = (kept.value.data as ProgramData).programStmts;
		assert stmts.length == 1 && stmts[0].flags.has(NodeFlag.WhenKept);
	}
}

test "fmt: a program parsed without its when branches is refused, not printed short" {
	const src = "when (neverDefinedA) {\n\tconst a = 1;\n}\nconst d = 4;\n";
	const parsed = parseSource(src);
	assert parsed.ok;
	if (parsed.ok) {
		const opts = defaultFormatOptions();
		opts.source = src;
		const out = formatNode(parsed.value, opts);
		assert !out.ok && out.error.contains("parseForFormat"), out.ok ? out.value : out.error;
	}
}
