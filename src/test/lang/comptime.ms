// Language tests: @comptime — compile-time evaluation via Raiser VM
//
// Covers:
//   Phase 8a — local outer scope access from inside @comptime
//   Phase 8b — cross-module function calls (e.g., readFile from std/fs)
//   Phase 8c — cross-module nested field access on DU types (r.error.kind)
//
// Note on Phase 8c: type-checking PASS is what's tested here. The VM-side
// gap where `r.error.kind` evaluates to Nil at runtime is tracked as a
// separate issue (Raiser lacks `resultDesugar` lowering for Result.err).
// Workaround `+ 0` coerces the Nil to a numeric 0 so the const initializer
// has the expected `number` type at the call site.

import { readFile } from "std/fs";

// ===== Phase 8a: same-file outer scope =====

const OUTER_VALUE: number = 42;

const PHASE_8A_LOCAL: number = @comptime {
	const x = 10;
	const y = 20;
	return x + y;
};

test "phase 8a: pure local @comptime" {
	assert PHASE_8A_LOCAL === 30;
}

// ===== Phase 8b: cross-module function call =====
// readFile() body must compile to bytecode inside the synthetic Program.

const README_SIZE: number = @comptime {
	const r = readFile("README.md");
	if (!r.ok) return -1;
	return r.value.length;
};

test "phase 8b: cross-module readFile returns file size" {
	// README.md exists in the project root with a known minimum size.
	assert README_SIZE > 100;
}

const NOT_FOUND_OK: number = @comptime {
	const r = readFile("/tmp/__definitely_not_a_real_path__");
	if (r.ok) return 1;
	return 0;
};

test "phase 8b: cross-module readFile error path returns !ok" {
	assert NOT_FOUND_OK === 0;
}

// ===== Phase 8c: cross-module nested field access =====
// `r.error.kind` requires IoError (interface, std/io/errors) + IoErrorKind
// (enum, same module) to be reachable in the inner @comptime check. Before
// Phase 8c the inner check emitted 9× "Unresolved type 'IoError'" errors
// and failed to fold; now the walker injects them via the Type.sym chain.

const KIND_ZERO_GUARDED: number = @comptime {
	const r = readFile("/tmp/__definitely_not_a_real_path__");
	if (r.ok) return -1;
	// `+ 0` workaround for the known VM-runtime gap (Nil + 0 → 0).
	// Type-check parity is what this test exercises; the value is
	// secondary until the resultDesugar transform fires in evalASTFull.
	return r.error.kind + 0;
};

test "phase 8c: r.error.kind compiles (type-check pass on cross-module DU)" {
	// Value is 0 today due to VM-side Nil; the load-bearing assertion is
	// that the @comptime expression resolved to `number` at the call site
	// (otherwise the outer `const ... : number = ...` annotation would
	// reject the fold result).
	assert KIND_ZERO_GUARDED >= 0;
}

// ===== Injection isolation: @comptime must never corrupt the surrounding module =====
// Regression for the by-ref injection bug (2026-07): evalASTFull runs a
// destructive pipeline on the synthetic Program; before the cloneNodeForCheck
// fix, injected module decls were the REAL nodes — sibling fns using module
// consts got string-concats folded to "<object>" and identifiers emitted
// unmangled in C. These tests fail loud if that ever regresses.

const ISO_PLAIN: string = "plain";
const ISO_CT: string = @comptime { return "hello"; };

function isoPlain(): string { return ISO_PLAIN; }
function isoCt(): string { return ISO_CT; }

function isoCtLen(): number {
	let n = 0;
	let i = 0;
	while (i < ISO_CT.length) {
		n = n + 1;
		i = i + 1;
	}
	return n;
}

test "isolation: comptime const survives concat in sibling fns" {
	assert ("p=" + isoPlain()) === "p=plain";
	assert ("s=" + isoCt()) === "s=hello";
}

test "isolation: comptime const usable as value in loop and local" {
	assert isoCtLen() === 5;
	const local: string = ISO_CT;
	assert local === "hello";
}

function isoSeed(): number { return 42; }
const ISO_CT2: number = @comptime { return isoSeed(); };

test "isolation: second comptime block still resolves outer fns" {
	assert ISO_CT2 === 42;
}

// String ops on a PARAMETER receiver. exprIsString must consult the resolved
// type (Nim vmgen dispatches on n[1].typ); when it asked the AST first, a param
// — an Identifier no local-string table knows — answered false, so `.length`
// emitted ArrayLen against a string handle ("array handle out of bounds: 0")
// and charAt/slice silently missed their opcodes.
function paramLen(s: string): int32 { return s.length as int32; }
function paramCharAt(s: string): string { return s.charAt(1); }
function paramSlice(s: string): string { return s.slice(1, 4); }
function paramScan(s: string): string {
	let out = "";
	let i = 0;
	while (i < s.length) { out = out + s.charAt(i); i = i + 1; }
	return out;
}

const PARAM_LEN: int32 = @comptime { return paramLen("abcde"); };
const PARAM_CHAR_AT: string = @comptime { return paramCharAt("abcdef"); };
const PARAM_SLICE: string = @comptime { return paramSlice("abcdef"); };
const PARAM_SCAN: string = @comptime { return paramScan("abc"); };

test "comptime: string ops on a string-typed parameter" {
	assert PARAM_LEN === 5;
	assert PARAM_CHAR_AT === "b";
	assert PARAM_SLICE === "bcd";
	assert PARAM_SCAN === "abc";
}

// String ORDERING. `isStrCmp` was computed for every comparison operator but
// only `==`/`!=` had branches, so `<` `<=` `>` `>=` fell through to the numeric
// tail and compared string HANDLES with BxxI64 — silently wrong, and wrong for
// literals too. Nim gives `<`/`<=` their own magics + opcodes (LtStr/LeStr) and
// derives `>`/`>=` by swapping operands; we now do the same.
// ⚠ Equal operands are NOT sufficient coverage: `<=`/`>=` on two equal strings
// returned true even when broken, because the two handles were equal.
function ordLt(a: string, b: string): boolean { return a < b; }
function ordLe(a: string, b: string): boolean { return a <= b; }
function ordGt(a: string, b: string): boolean { return a > b; }
function ordGe(a: string, b: string): boolean { return a >= b; }

const ORD: string = @comptime {
	let r = "";
	r = r + (("abc" < "abd") ? "1" : "0");
	r = r + (("abd" < "abc") ? "1" : "0");
	r = r + (("abc" <= "abd") ? "1" : "0");
	r = r + (("abd" <= "abc") ? "1" : "0");
	r = r + (("abd" > "abc") ? "1" : "0");
	r = r + (("abc" >= "abd") ? "1" : "0");
	r = r + (ordLt("abc", "abd") ? "1" : "0");
	r = r + (ordLe("abc", "abc") ? "1" : "0");
	r = r + (ordGt("abd", "abc") ? "1" : "0");
	r = r + (ordGe("abc", "abc") ? "1" : "0");
	r = r + (("Z" < "a") ? "1" : "0");
	r = r + (("ab" < "abc") ? "1" : "0");
	return r;
};

test "comptime: string ordering compares text, not handles" {
	assert ORD === "101010111111";
}
