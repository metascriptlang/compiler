import { checkOnly } from "../helpers";

const SRC_FORWARD = `
struct Box { n: int32; }
function make(): Box { return { n: 7 }; }
function show(): number { return LATER + count + BOX.n; }
function flag(): boolean { return block; }
const LATER = 41;
let count = 1;
let block = false;
const BOX = make();
`;

const SRC_FORWARD_MISMATCH = `
function show(): string { return LATER; }
const LATER = 41;
`;

const SRC_SELF = `
const x = x + 1;
`;

const SRC_ROUTINE_FIRST = `
function f() { return a; }
const a = f();
`;

const SRC_BINDING_FIRST = `
const a = f();
function f() { return a; }
`;

const SRC_SIGNATURE_TYPED = `
function show(): int32 { return fact(4); }
const fact = (n: int32): int32 => n <= 1 ? 1 : n * fact(n - 1);
`;

const SRC_ANNOTATED_CLOSURE = `
const handlers: (() => void)[] = [];
function on(f: () => void): int32 { handlers.push(f); return handlers.length as int32; }
const id: int32 = on((): void => { console.log(id + 1); });
`;

test "a module binding without an annotation read above its declaration has its initializer's type" {
	const result = checkOnly(SRC_FORWARD);
	assert result.errors.length == 0, "forward reads of unannotated module bindings must check: " + result.errors.join("\n");
}

test "a forward read of an unannotated module binding is checked against its initializer's type" {
	const text = checkOnly(SRC_FORWARD_MISMATCH).errors.join("\n");
	assert text.contains("string"), "a number binding returned as string must be refused: " + text;
}

test "a module binding read by its own initializer is refused" {
	const text = checkOnly(SRC_SELF).errors.join("\n");
	assert text.contains("cannot infer the type of 'x': its own initializer reads it; annotate the type of 'x'"), "a self-read initializer must be refused: " + text;
}

test "a routine read back by the binding it initializes names the cycle" {
	const text = checkOnly(SRC_ROUTINE_FIRST).errors.join("\n");
	assert text.contains("cannot infer the return type of 'f': 'a' reads it while 'f' is still being checked (f -> a -> f)"), "f -> a -> f must be refused: " + text;
}

test "a binding read back by the routine its initializer calls names the cycle" {
	const text = checkOnly(SRC_BINDING_FIRST).errors.join("\n");
	assert text.contains("cannot infer the type of 'a': 'f' reads it while 'a' is still being checked (a -> f -> a)"), "a -> f -> a must be refused: " + text;
}

test "a closure binding typed by its signature calls itself and is read from above" {
	const result = checkOnly(SRC_SIGNATURE_TYPED);
	assert result.errors.length == 0, "a signature-typed recursive closure must check: " + result.errors.join("\n");
}

test "an annotated binding read inside a closure in its own initializer checks" {
	const result = checkOnly(SRC_ANNOTATED_CLOSURE);
	assert result.errors.length == 0, "an annotated binding needs no inference: " + result.errors.join("\n");
}
