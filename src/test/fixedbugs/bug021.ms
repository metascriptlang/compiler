// bug021 — Parser rejected `(): T => ...` (zero-param arrow with explicit
// return-type annotation). The lookahead in `isArrowFunction` only accepted
// the strict `( ) =>` pattern for the zero-param case, while the multi-param
// and destructured/default paths already routed through `scanParenForArrow`
// which knows how to walk past an optional `: Type` return annotation. The
// inconsistency meant `(): void => {...}`, `(): int32 => 42`, etc. all fell
// through to paren-expression parsing and blew up on the unexpected `:`,
// emitting a cascade of "Unexpected token: )/}/;" errors.
//
// Symptom:    `Parse: Unexpected token: ) at line N` for any `(): T => ...`.
// Root cause: src/parser/expressions/arrow.ms:71 isArrowFunction — zero-param
//             branch only accepted `peek(2) === Arrow`; missing `Colon` case.
// Fix:        When p1 is RParen, also handle `p2 === Colon` by routing
//             through the existing `scanParenForArrow` helper (the same
//             helper used by destructured-param and default-value paths).

import { compileToC } from "../helpers";

test "bug021: zero-param arrow with void return type parses" {
	const src = `
function main(): void {
	const f = (): void => { return; };
	f();
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: zero-param arrow with int32 return type parses" {
	const src = `
function main(): void {
	const f = (): int32 => 42;
	if (f() !== 42) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: zero-param arrow with string return type parses" {
	const src = `
function main(): void {
	const f = (): string => "hello";
	if (f().length !== 5) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: zero-param arrow with generic return type parses" {
	const src = `
interface Box<T> { v: T; }
function main(): void {
	const f = (): Box<int32> => ({ v: 42 });
	if (f().v !== 42) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: zero-param arrow in callback arg parses" {
	const src = `
function call(fn: () => int32): int32 { return fn(); }
function main(): void {
	const r = call((): int32 => 42);
	if (r !== 42) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: zero-param arrow as object literal field parses" {
	const src = `
interface Builder { make: () => int32; }
function main(): void {
	const b: Builder = { make: (): int32 => 42 };
	if (b.make() !== 42) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: zero-param arrow with array return type parses" {
	const src = `
function main(): void {
	const f = (): int32[] => [1, 2, 3];
	if (f().length !== 3) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: zero-param async arrow with return type parses" {
	const src = `
async function main(): Promise<void> {
	const f = async (): int32 => 42;
	const v = await f();
	if (v !== 42) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: control — no-annotation arrow still parses (no regression)" {
	const src = `
function main(): void {
	const f = () => "hi";
	if (f().length !== 2) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}

test "bug021: control — multi-param + return type still parses (no regression)" {
	const src = `
function main(): void {
	const f = (x: int32): int32 => x * 2;
	if (f(21) !== 42) return;
}
`;
	const c = compileToC(src);
	assert c.ok;
}
