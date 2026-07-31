// nim-guard: string immutable surface — the STRING-CONTRACT lock-in must keep firing
//
// INVARIANT (docs/STRING-CONTRACT.md §1 + NIM-REF row "String mutability
//   contract"): `string` is observably immutable at the language surface on
//   every backend. The checker rejects index-assign (`s[i] = c`, compound
//   forms too) and length-assign; the byte-mutation story is the uint8[]
//   buffer tier (asBytes/asString). The C engine keeps its INTERNAL mutation
//   tier (msStringSetChar/SetLength/SetSlice) — this guard pins the surface,
//   not the engine.
//
// WHAT IT CATCHES: a checker refactor dropping the surface rejection. The
//   pre-contract state let `s[i] = "x"` through the checker and died at
//   clang ("passing 'msString' to parameter of incompatible type
//   'msString *'") — a fail-ugly path one emit fix away from becoming a
//   silent mutable surface that breaks the contract everywhere downstream
//   (js native strings, native Map/Set keys).
//
// RED MEANS: checkExprPass lost the ArrayAccess-string assignment arm or
//   the length readonly arm, or the messages were reworded (retag only with
//   a STRING-CONTRACT amendment). Proven red 2026-08-01 against the
//   pre-contract HEAD binary: it builds this file into a CLANG error, so
//   the build fails WITHOUT the tags below → "missing tag" red.
//
// GUARD-CHECK-FAIL strings are immutable - mutate bytes via uint8[]
// GUARD-CHECK-FAIL cannot assign to 'length' on string

function main(): void {
	let s = "abc";
	s[0] = "x";
	s[1] += "y";
	s.length = 2;
	console.log(s);
}
main();
