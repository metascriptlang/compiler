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

import { ObjKind } from "./obj";
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

test "a C23 fixed underlying type sets the enum's size and signedness" {
	const src = "typedef enum : unsigned char { A = 1 } U8;\n"
		+ "typedef enum Tag : int { B = -1 } Named;\n"
		+ "typedef unsigned short u16;\n"
		+ "enum Wide : u16 { C = 1 };\n"
		+ "enum Fwd : long long;\n"
		+ "enum Fwd : long long { D = 1 };\n"
		+ "struct S { enum Wide w : 3; };\n";
	const out = parseHeader(src, "fixed.h", defaultOptions());
	assert out.diagnostics.length == 0, out.diagnostics[0].message;
	let u8 = -1;
	let named = -1;
	let wide = -1;
	let fwd = -1;
	for (const o of out.objs) {
		if (o.kind == ObjKind.EnumConstant && o.name == "A") u8 = o.type.size;
		if (o.kind == ObjKind.EnumConstant && o.name == "B") named = o.type.size;
		if (o.kind == ObjKind.EnumConstant && o.name == "C") wide = o.type.size;
		if (o.kind == ObjKind.EnumConstant && o.name == "D") fwd = o.type.size;
	}
	assert u8 == 1;
	assert named == 4;
	assert wide == 2;
	assert fwd == 8;
}

test "a token no rule consumes is a diagnostic, not a hang" {
	const out = parseHeader("typedef int : 3;\nint after;", "stuck.h", defaultOptions());
	assert out.diagnostics.length == 1;
	assert out.diagnostics[0].message.includes("':'"), out.diagnostics[0].message;
	assert out.objs[out.objs.length - 1].name == "after";
}
