// @stdout: true x true true none true
// note: a top-level binding typed by a literal type and set from a match built on C with the module init assigning `MS_NIL` to its slot. Variants: enum literal, string literal, `true`, `Kind | null` (some and none) and the same enum-literal binding inside a function.

enum Kind { A, B }
const n = "ab".length - 1;
const lit: Kind.A = match (n) { 1 => Kind.A, _ => Kind.A };
const str: "x" = match (n) { 1 => "x", _ => "x" };
const yes: true = match (n) { 1 => true, _ => true };
const some: Kind | null = match (n) { 1 => Kind.B, _ => null };
const none: Kind | null = match (n) { 0 => Kind.B, _ => null };

function local(): boolean {
	const l: Kind.A = match (n) { 1 => Kind.A, _ => Kind.A };
	return l == Kind.A;
}

console.log(lit == Kind.A, str, yes, some == Kind.B, none == null ? "none" : "some", local());
