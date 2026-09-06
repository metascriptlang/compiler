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

test "end-to-end function declaration parses" {
	const out = parseHeader("int add(int a, int b);", "add.h", defaultOptions());
	assert out.diagnostics.length == 0;
	assert out.objs.length > 0;
}
