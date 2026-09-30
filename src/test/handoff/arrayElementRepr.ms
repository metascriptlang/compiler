// Checker — container element-repr invariance, enforced centrally in fitNode.
//
// A ref array/span/ptr is assigned by a raw payload cast with no per-element
// conversion, so assigning int32[] (4B elements) where number[] (8B) is expected
// reinterprets the buffer → out-of-bounds read. Nim's typeRel keeps sequence/array
// elements invariant (sigmatch.nim:1502); MS enforces the same at fitNode, so every
// assignment site (var-decl, return, field, array element, ternary, arg) is covered
// by one check.

import { strictErrorCount } from "./helpers";

// ===== Rejected: element repr differs (int32 vs number) =====

test "var-decl int32[] → number[] is rejected" {
	assert strictErrorCount("function f(): number { const src: int32[] = [1, 2]; const dst: number[] = src; return dst[0]; }") == 1;
}

test "return int32[] as number[] is rejected" {
	assert strictErrorCount("function f(): number[] { const src: int32[] = [1, 2]; return src; }") == 1;
}

test "field-init int32[] into number[] field is rejected" {
	assert strictErrorCount("struct Box { data: number[]; } function f(): void { const src: int32[] = [1, 2]; const b: Box = { data: src }; }") == 1;
}

test "array-element int32[] into number[][] is rejected" {
	assert strictErrorCount("function f(): void { const src: int32[] = [1, 2]; const outer: number[][] = [src]; }") == 1;
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

test "array storage: constant indexes respect sized bounds while dynamic indexes retain runtime checking" {
	const cases = [
		{ source: "function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[3]; }", errors: 0 },
		{ source: "function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[4]; }", errors: 1 },
		{ source: "function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[5]; }", errors: 1 },
		{ source: "function f(): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[-1]; }", errors: 1 },
		{ source: "function f(): void { let a: int32[4] = [1, 2, 3, 4]; a[4] = 9; }", errors: 1 },
		{ source: "function f(): string { let a: string[2] = [\"x\", \"y\"]; return a[2]; }", errors: 1 },
		{ source: "function f(i: int32): int32 { let a: int32[4] = [1, 2, 3, 4]; return a[i]; }", errors: 0 },
		{ source: "function f(): int32 { const a: int32[] = [1, 2, 3]; return a[5]; }", errors: 0 },
		{ source: "function f(): int32 { let a: int32[1] = [7]; return a[0]; }", errors: 0 },
		{ source: "function f(): int32 { let a: int32[1] = [7]; return a[1]; }", errors: 1 },
	];
	for (const item of cases) {
		assert strictErrorCount(item.source) == item.errors, item.source;
	}
}
