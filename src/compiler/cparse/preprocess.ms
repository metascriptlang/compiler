// cparse — C preprocessor
// Port of: ~/projects/chibicc preprocess.c
//
// STATUS: skeleton. Real implementation lands in task #15.

import { Token, makeEofToken } from "./token";
import { Diagnostic } from "./error";
import { TargetInfo } from "./target";

export interface PreprocessResult {
	head: Token;
	diagnostics: Diagnostic[];
}

// Expand #include, #define, #if/#ifdef, ## paste, # stringify, _Pragma,
// __has_include, __has_feature. Runs sequentially within a single translation
// unit; parallelism across headers happens at a higher layer (main.ms spawns
// one job per header, HeaderCache actor deduplicates).
//
// TODO(task #15): full port of chibicc preprocess.c + bindgen extensions:
//   - __has_include / __has_feature / __has_attribute / __has_builtin
//   - Ingest predefined macros from target.ms
//   - #pragma once tracked via shared HeaderCache
export function preprocess(
	head: Token,
	target: TargetInfo,
	includePaths: string[]
): PreprocessResult {
	// Skeleton: pass-through.
	return { head, diagnostics: [] };
}

test "preprocess empty token stream is a no-op" {
	const eof = makeEofToken("empty.h");
	const r = preprocess(eof, {} as unknown as TargetInfo, []);
	assert r.head === eof;
}
