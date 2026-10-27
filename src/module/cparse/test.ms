// cparse — Aggregate test entry
//
// Unit tests live inside each phase file (token.ms, target.ms, type.ms,
// error.ms, tokenize.ms, preprocess.ms). This file imports them so a
// single `msc test` invocation runs the whole suite, plus adds end-to-end
// integration tests for the public API in ../cimport/index.ms.

import "./token";
import "./target";
import "./type";
import "./error";
import "./tokenize";
import "./preprocess";

import { parseHeader, defaultOptions } from "../cimport/index";

test "end-to-end skeleton runs without crashing" {
	const out = parseHeader("", "empty.h", defaultOptions());
	assert out.objs.length == 0;
	assert out.diagnostics.length == 0;
}

test "a tag-only declaration declares the tag, not a variable" {
	const out = parseHeader("struct S;\nunion U;\nenum E;\nstruct S* get(void);", "tags.h", defaultOptions());
	assert out.diagnostics.length == 0;
	assert out.objs.length == 1;
	assert out.objs[0].name == "get";
	assert out.objs[0].type.returnType.base.tagName == "S";
}

test "end-to-end function declaration parses" {
	const out = parseHeader("int add(int a, int b);", "add.h", defaultOptions());
	assert out.diagnostics.length == 0;
	assert out.objs.length > 0;
}

test "a bit-field width is a constant expression" {
	const out = parseHeader("enum { K = 5 };\nstruct S { int a : K; int b : (1 + 2); int c; } v;", "bits.h", defaultOptions());
	assert out.diagnostics.length == 0;
	const members = out.objs[1].type.members;
	assert members[0].bitWidth == 5;
	assert members[1].bitWidth == 3;
	assert members[2].bitWidth == null;
}

test "an unknown identifier in an array size is a diagnostic" {
	const out = parseHeader("int a[NOPE];", "arr.h", defaultOptions());
	assert out.diagnostics.length == 1;
	assert out.diagnostics[0].message.includes("NOPE");
}

test "an unknown identifier in a bit-field width is a diagnostic" {
	const out = parseHeader("struct S { int b : NOPE; };", "bits.h", defaultOptions());
	assert out.diagnostics.length == 1;
	assert out.diagnostics[0].message.includes("NOPE");
}

test "an unknown identifier in an enum value is a diagnostic" {
	const out = parseHeader("enum { A = NOPE };", "enum.h", defaultOptions());
	assert out.diagnostics.length == 1;
	assert out.diagnostics[0].message.includes("NOPE");
}

test "an identifier left in an #if expression is 0" {
	const out = parseHeader("#if UNDEFINED_NAME\nint no;\n#else\nint yes;\n#endif\n", "if.h", defaultOptions());
	assert out.diagnostics.length == 0;
	assert out.objs.length == 1;
	assert out.objs[0].name == "yes";
}
