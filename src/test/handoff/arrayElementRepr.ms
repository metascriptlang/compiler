// Checker — container element-repr invariance, enforced centrally in fitNode.
//
// A ref array/span/ptr is assigned by a raw payload cast with no per-element
// conversion, so assigning int32[] (4B elements) where number[] (8B) is expected
// reinterprets the buffer → out-of-bounds read. Nim's typeRel keeps sequence/array
// elements invariant (sigmatch.nim:1502); MS enforces the same at fitNode, so every
// assignment site (var-decl, return, field, array element, ternary, arg) is covered
// by one check.

import { strictErrorCount, hasError } from "./helpers";

// ===== Rejected: element repr differs (int32 vs number) =====

test "var-decl int32[] → number[] is rejected" {
	assert hasError("function f(): number { const src: int32[] = [1, 2]; const dst: number[] = src; return dst[0]; }", "reinterpret");
}

test "return int32[] as number[] is rejected" {
	assert hasError("function f(): number[] { const src: int32[] = [1, 2]; return src; }", "reinterpret");
}

test "field-init int32[] into number[] field is rejected" {
	assert hasError("struct Box { data: number[]; } function f(): void { const src: int32[] = [1, 2]; const b: Box = { data: src }; }", "reinterpret");
}

test "array-element int32[] into number[][] is rejected" {
	assert hasError("function f(): void { const src: int32[] = [1, 2]; const outer: number[][] = [src]; }", "reinterpret");
}

// ===== Allowed: same repr, or scalar widening (not a container reinterpret) =====

test "var-decl number[] → number[] is allowed" {
	assert strictErrorCount("function f(): number { const src: number[] = [1.0, 2.0]; const dst: number[] = src; return dst[0]; }") == 0;
}

test "var-decl int32[] → int32[] is allowed" {
	assert strictErrorCount("function f(): int32 { const src: int32[] = [1, 2]; const dst: int32[] = src; return dst[0]; }") == 0;
}

test "scalar int32 → number widening is allowed (not a container)" {
	assert strictErrorCount("function f(): number { const a: int32 = 5; const b: number = a; return b; }") == 0;
}
