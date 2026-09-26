// bug240 — an enum member argument bound a type parameter to its literal type
//
// Symptom:    `pair(K.A, K.B)` failed with "got K.B, expected K.A — 'T' was bound by argument 0";
//             `let k = id(K.A); k = K.B` was refused; once the arguments bound first,
//             `return Result.err(Failure.Rejected)` into `Result<uint64, Failure>` bound `E` to
//             `Failure.Rejected` and C emitted two Result structs (pinned by corpus 829).
// Root cause: the call-argument walk narrows an enum member to its EnumLiteral type to match a
//             literal-typed parameter, and forward inference bound `T` to that narrowed type.
// Fix:        the narrowing applies only against a formal without type parameters; a type
//             parameter binds the member's enum, as an unannotated `const k = K.A` widens to `K`
//             (LANG "Enum Literal Types"; the reference has no enum literal types).

import { compileToC, compileToJS } from "../helpers";

const header = `
enum K { A, B, C }
function id<T>(x: T): T { return x; }
function pair<T>(a: T, b: T): T[] { return [a, b]; }
function tag<T>(x: T, k: K.A): T { return x; }
function handleA(k: K.A): int32 { return 1; }
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	if (!c.ok) return c.error;
	const js = compileToJS(header + body);
	return js.ok ? "" : js.error;
}

test "bug240: two members of one enum bind T to the enum" {
	assert errorOf("const xs = pair(K.A, K.B); console.log(xs.length);") == "";
}

test "bug240: a member bound through a generic widens to its enum" {
	assert errorOf("let k = id(K.A); k = K.B; console.log(k == K.B);") == "";
}

test "bug240: a literal-typed parameter beside a type parameter keeps the literal" {
	assert errorOf("console.log(tag(5, K.A));") == "";
	assert errorOf("console.log(tag(5, K.B));").contains("got K.B, expected K.A");
}

test "bug240: a literal-typed parameter still refuses another member" {
	assert errorOf("console.log(handleA(K.B));").contains("got K.B, expected K.A");
}
