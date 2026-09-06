// bug110 — a pointer-shaped value in a scalar slot passed the checker
//
// Symptom:    `const x: int32 = new QA()`, `x = qa` and `const r: QA = 5`
//             all reached clang, which rejected them with -Wint-conversion.
//             The argument path rejected the very same pair correctly, so the
//             two fit doors disagreed about one relation.
// Root cause: isReinterpretUnsafeInner bailed on `source.kind !== target.kind`
//             before looking at repr at all, so fitNode's only gate could
//             never fire on a pointer/scalar pair.
// Fix:        Nim typeRel yields isNone for a scalar actual against a ref/ptr
//             formal (sigmatch.nim:1577 `of tyPtr, tyRef`: same-kind or nil,
//             everything else falls through to `discard`). fitNode now rejects
//             the pointer-vs-scalar pair at every fit site. The Ref→Ptr cursor
//             coercion (NIM-REF.md §4) is untouched — both sides are pointers.

import { hasError, strictErrorCount } from "../handoff/helpers";

test "bug110: a ref initializing an int32 slot is rejected" {
	assert hasError("class B110A { v: int32; } function f(): void { const a = new B110A(); const x: int32 = a; }", "memory layout differs");
}

test "bug110: a ref assigned into an int32 slot is rejected" {
	assert hasError("class B110A { v: int32; } function f(): void { const a = new B110A(); let x: int32 = 0; x = a; }", "memory layout differs");
}

test "bug110: an int initializing a ref slot is rejected" {
	assert hasError("class B110A { v: int32; } function f(): void { const r: B110A = 5; }", "memory layout differs");
}

test "bug110: an array initializing a scalar slot is rejected" {
	assert hasError("function f(): void { const arr: int32[] = [1, 2]; const n: int32 = arr; }", "memory layout differs");
}

test "bug110: a ref returned as a scalar is rejected" {
	assert hasError("class B110A { v: int32; } function f(): int32 { const a = new B110A(); return a; }", "memory layout differs");
}

// Neighbours that bound the rule — each must stay legal.

test "bug110: Ref<T> → Ptr<T> cursor init stays legal" {
	assert strictErrorCount("class B110B { v: int32; next: Ptr<B110B>; } function f(): void { const t = new B110B(); const p: Ptr<B110B> = t; }") == 0;
}

test "bug110: Ptr<T> → Ref<T> read stays legal" {
	assert strictErrorCount("class B110B { v: int32; next: Ptr<B110B>; } function g(t: B110B): void { } function f(): void { const t = new B110B(); const e = new B110B(); t.next = e; g(t.next); }") == 0;
}

test "bug110: scalar widening stays legal" {
	assert strictErrorCount("function f(): void { const a: int32 = 1; const b: int64 = a; const c: float64 = a; const d: number = a; }") == 0;
}

test "bug110: enum and int share the scalar class" {
	assert strictErrorCount("enum B110C { Red, Green } function f(): void { const e = B110C.Red; const n: int32 = e as int32; }") == 0;
}

// The string family is deliberately outside this rule: msString is its own repr
// with real conversions, and int32→string is a separate latent fillDefaults bug.
test "bug110: the string family is not routed through this rule" {
	assert !hasError("function f(): void { const n: int32 = 1; const s: string = n; }", "memory layout differs");
}
