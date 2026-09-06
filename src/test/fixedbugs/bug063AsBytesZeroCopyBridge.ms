// bug063 — asBytes/asString zero-copy bridge miscompiled on the C backend
//
// Symptom:    `"abc".asBytes()` died in clang in EVERY form (local binding,
//             direct chain, for-of):
//                 assigning to 'msUint8Array *' from incompatible type
//                 'msUint8Array'; remove *
//             Declared since the builtin landed (`@builtin("AsBytes")` in
//             index.cms) but NO std code ever called it on the C path, so it
//             shipped unexercised. Same root for `@builtin("AsString")`.
//
// Root cause: Both directions lower to HiddenStdConv + Cursor, and the C
//             emission used ONE cast shape `*((T*)&(inner))` — written for a
//             value-to-value cast. But the two reprs differ: string is a fat
//             VALUE (msString {len,p}) while uint8[] locals are POINTERS
//             (msUint8Array*). string→bytes needs `((msUint8Array*)&(inner))`
//             (address-of the value, keep the pointer); bytes→string needs
//             `*((msString*)(inner))` (already a pointer, deref to a value).
//
// Fix:        codegen/c/expressions.ms HiddenStdConv Cursor branch picks the
//             cast shape by convType.kind (Array vs value target).
//
// This is the kernel pair the single-source std plan stands on: shared byte-
// loop algorithms do `s.asBytes()` on entry and `bytes.asString()` on exit.
//
// ⚠ Scope (audit 2026-07-29, probes audit1-3): these tests are IN-SCOPE only.
// The bridge's ownership model is still incomplete — an rvalue receiver fails
// C compile (`(a+b).asBytes()`), returning `buf.asString()` across a function
// boundary dangles (Cursor-borrow, array payload freed at scope end — measured
// UAF), and mutating a borrowed view writes through to the source string.
// BUGS.md §2 "zero-copy bridge ownership" row tracks all three.

test "bug063: asBytes through a local binding" {
	const sb = "abc".asBytes();
	assert sb.length == 3;
}

test "bug063: asBytes direct chain" {
	assert "abc".asBytes().length == 3;
}

test "bug063: asBytes element reads see the string's bytes" {
	const sb = "abc".asBytes();
	assert sb[0] == 97;
	assert sb[2] == 99;
}

test "bug063: asBytes borrow survives for-of" {
	let total: int32 = 0;
	for (const b of "xyz".asBytes()) {
		total = total + (b as int32);
	}
	assert total == 363;
}

test "bug063: asString round-trips" {
	const b = "hello".asBytes();
	const s = b.asString();
	assert s == "hello";
	assert s.length == 5;
	assert "round".asBytes().asString() == "round";
}

test "bug063: empty string round-trips" {
	const empty = "".asBytes();
	assert empty.length == 0;
	assert empty.asString().length == 0;
}

test "bug063: asString on a built uint8[] (the buildString exit path)" {
	const bytes: uint8[] = [];
	bytes.push(104);
	bytes.push(105);
	assert bytes.asString() == "hi";
}
