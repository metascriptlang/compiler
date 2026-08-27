// bug111 — null needed an `as unknown as` cast to enter any Cursor slot, and
//          null assigned into a non-nullable ref slot passed the checker
//
// Symptom:    `next: null` in an object literal against `Cursor<T>` was
//             rejected ("not assignable"), forcing every construction site
//             through `null as unknown as T`; meanwhile `h.p = null` on a
//             plain ref field compiled silently — the assignment door never
//             consulted the relation for a Null RHS.
// Root cause: (a) no allowsNil arm — sigmatch.nim:730 `allowsNil` admits nil
//             into any nilable pointer class; Cursor is the {.cursor.} analog,
//             whose null state (end of chain) is intrinsic. skipModifier peels
//             Cursor at isAssignable entry, so the arm must sit BEFORE it.
//             (b) BinaryExpr "=" ran fitNode but never the relation itself
//             (semAsgn -> fitNode -> typeRel parity, semexprs.nim:2026), so a
//             Null RHS slipped through every assignment.
// Fix:        pre-peel Null->Cursor arm in isAssignableInner + Null-RHS
//             enforcement in the "=" arm of checkExprPass, scoped to Null so
//             the terminal fitNode scope (NIM-REF row 80) stays closed.
//             Ref/Ptr stay TS-strict (`T | null` opt-in) — pinned below.

import { hasError, strictErrorCount } from "../handoff/helpers";

test "bug111: bare null initializes a Cursor field" {
	assert strictErrorCount("interface B111A { tag: string; next: Cursor<B111A>; } function f(): void { const a: B111A = { tag: \"x\", next: null }; }") === 0;
}

test "bug111: bare null assigns into a Cursor field" {
	assert strictErrorCount("interface B111A { tag: string; next: Cursor<B111A>; } function f(a: B111A): void { a.next = null; }") === 0;
}

test "bug111: a ref assigns into a Cursor field" {
	assert strictErrorCount("interface B111A { tag: string; next: Cursor<B111A>; } function f(): void { const a: B111A = { tag: \"x\", next: null }; const b: B111A = { tag: \"y\", next: null }; a.next = b; }") === 0;
}

test "bug111: null into a plain ref field by assignment is rejected" {
	assert hasError("interface B111P { tag: string; } interface B111H { p: B111P; } function f(h: B111H): void { h.p = null; }", "not assignable");
}

test "bug111: null into a plain ref local by assignment is rejected" {
	assert hasError("interface B111P { tag: string; } function f(): void { let p: B111P = { tag: \"x\" }; p = null; }", "not assignable");
}

test "bug111: null into a T | null field stays legal" {
	assert strictErrorCount("interface B111P { tag: string; } interface B111H { p: B111P | null; } function f(h: B111H): void { h.p = null; }") === 0;
}

test "bug111: null into a bare Ptr field literal stays rejected" {
	assert hasError("interface B111P { tag: string; next: Ptr<B111P>; } function f(): void { const a: B111P = { tag: \"x\", next: null }; }", "not assignable");
}
