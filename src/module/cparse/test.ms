// cparse — Aggregate test entry
//
// Unit tests live inside each phase file (token.ms, target.ms, type.ms,
// error.ms, tokenize.ms, preprocess.ms). This file imports them so a
// single `test-ms` invocation runs the whole suite, plus adds end-to-end
// integration tests for the public API in index.ms.

import "./token";
import "./target";
import "./type";
import "./error";
import "./tokenize";
import "./preprocess";

import { parseHeader, defaultOptions } from "./index";

test "end-to-end skeleton runs without crashing" {
	const out = parseHeader("", "empty.h", defaultOptions());
	assert out.msSource === "";
	assert out.diagnostics.length === 0;
}

// TODO: acceptance tests that exercise the full pipeline against
// fixture headers once tokenize/preprocess/parse land.
//
// Planned tests:
//   - "tokenize simple header" — once tokenize.ms is populated
//   - "preprocess ifdef branches" — once preprocess.ms handles #if
//   - "parse typedef struct" — once parse.ms declarator code exists
//   - "emit extern struct" — once emit.ms walks Obj
//   - "parallel bind 50 fixtures" — once parseHeaders path is wired end-to-end
//   - "HeaderCache dedup one tokenize for N calls" — cache hit-rate test
