// bug030 — Raiser compileExpr missing Hidden* handlers caused silent
//          nil fallthrough for every Ref<Struct> chain access in @comptime.
//
// Symptom:    @comptime block doing `o.inner.msg.length` where `o.inner` has
//             a Ref<Struct> field type silently returned 0 (Nil) instead of
//             the real value. Phase 8c case `r.error.kind` /
//             `r.error.message.length` / `r.error.path.length` all returned
//             0 even though the underlying IoError struct was constructed
//             with correct field values.
//
// Root cause: `src/codegen/raiser/expressions.ms compileExpr` match block
//             had no arms for `NodeKind.HiddenDeref`, `HiddenAddr`,
//             `HiddenStdConv`, `HiddenSubConv`. The checker inserts these
//             markers around access into Ref<Struct> types (and around
//             implicit type conversions). With no handler, dispatch fell
//             through to the default `_ => { LoadConst nil }` arm, emitting
//             a stray nil register. The subsequent `LoadField` then loaded
//             from nil → MISS → returned Nil → entire chain produced 0.
//
// Disasm before fix:
//   0: Call R0          ; const o = inlineInside()
//   1: LoadConst R1 nil ; ← HiddenDeref(o.inner) fell through
//   2: LoadField R2 R1  ; load "msg" from NIL → MISS
//   3: StrLen R3 R2     ; length of Nil = 0
//   4: Ret R3
//
// Fix:        Add passthrough arms for the 4 Hidden* node kinds (mirrors C
//             backend `src/codegen/c/expressions.ms:1599,1623,1638` and JS
//             backend `src/codegen/js/jsgen.ms:81-82` — both already emit
//             passthrough / inner-compile for these markers). Raiser VM has
//             no static-typed register file so deref/addr/conv are
//             implicit at runtime — pure passthrough is correct here.
//
// Touched:    src/codegen/raiser/expressions.ms (added 2 match arms after
//             MoveExpr handler, imported HiddenDerefData/HiddenStdConvData)

import { evalSourceFull } from "../../codegen/raiser/eval";

test "bug030: chained Ref<Struct> field access returns real value not Nil" {
	// Repro: `o.inner.msg.length` where Inner is a Ref<Struct> field.
	// Checker wraps `o.inner` in HiddenDeref. Without our fix the chain
	// loaded from nil and StrLen returned 0; with the fix, length is 11.
	const src = `
		interface Inner { msg: string; }
		interface Outer { inner: Inner; }
		function makeInner(): Inner { return { msg: "hello_world" }; }
		function inlineInside(): Outer { return { inner: makeInner() }; }
		const o = inlineInside();
		return o.inner.msg.length;
	`;
	const ctx = evalSourceFull(src);
	// "hello_world".length === 11
	assert ctx.lastResult.intVal === 11;
}

test "bug030: nested ObjectLiteral with inline call passes object handle" {
	// Same shape that surfaces in Phase 8c readFile → ioErrorFromErrno
	// → Result.err({...}) chain: an outer ObjectLiteral's field value
	// is a CallExpr that returns an object handle. The HiddenDeref
	// fallthrough corrupted the chain. With fix, the handle survives
	// across StoreField → caller LoadField round-trip.
	const src = `
		interface Inner { tag: number; }
		interface Outer { inner: Inner; }
		function makeInner(t: number): Inner { return { tag: t }; }
		function inlineInside(): Outer { return { inner: makeInner(42) }; }
		const o = inlineInside();
		return o.inner.tag;
	`;
	const ctx = evalSourceFull(src);
	assert ctx.lastResult.intVal === 42;
}
