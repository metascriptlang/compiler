// The comma after a match case.
//
// Symptom:    `match (i) { 2 => { break; } _ => {} }` formatted to
//             `match (i) {2 => { break; },_ => {},};`; the lossless check refused
//             every match whose block arms were written without commas.
// Root cause: the parser accepts the comma between cases as optional and kept no
//             record of it, and printMatchCase printed one after every case.
// Fix:        the parser flags a case written with a comma (CommaWritten); the
//             printer writes a comma where the source had one, after an expression
//             body in the last case, and after every expression body of a match
//             printed without its source, where a missing comma could join two cases.

import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";
import { parseSource } from "../../../parser/statements/validation";
import { resetAllSideChannels } from "../../../parser/context";
import { formatNode } from "../../../compiler/fmt/printer/index";
import { defaultFormatOptions } from "../../../compiler/fmt/options";

const LOOP = "let n: int32 = 0;\nfor (let i: int32 = 0; i < 4; i++) {\n";

test "fmt: block arms written without commas stay without commas" {
	assert assertFmtLossless(LOOP + "\tmatch (i) {\n\t\t2 => { break; }\n\t\t_ => {}\n\t}\n}\n");
	assert assertFmtPreservesAst(LOOP + "\tmatch (i) {\n\t\t2 => { break; }\n\t\t_ => {}\n\t}\n}\n");
}

test "fmt: block arms written with commas keep them" {
	assert assertFmtLossless(LOOP + "\tmatch (i) {\n\t\t2 => { break; },\n\t\t_ => { n = n + i; },\n\t}\n}\n");
}

test "fmt: expression arms keep the commas as written" {
	assert assertFmtLossless("const k: int32 = 2;\nconst s = match (k) {\n\t1 => \"one\",\n\t_ => \"many\"\n};\n");
	assert assertFmtLossless("const k: int32 = 2;\nconst s = match (k) {\n\t1 => \"one\"\n\t_ => \"many\",\n};\n");
}

test "fmt: a match printed without its source separates expression arms" {
	resetAllSideChannels();
	const parsed = parseSource("const k: int32 = 2;\nconst s = match (k) {\n\t1 => \"one\"\n\t_ => \"many\"\n};\n");
	assert parsed.ok;
	if (parsed.ok) {
		const out = formatNode(parsed.value, defaultFormatOptions());
		assert out.ok && out.value.contains("1 => \"one\","), out.ok ? out.value : out.error;
	}
}
