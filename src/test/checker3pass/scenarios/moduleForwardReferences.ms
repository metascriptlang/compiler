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

const SRC_TOP_LET = `
console.log(x);
let x = 5;
`;

const SRC_TOP_CONST = `
if (true) { console.log(y); }
const y: int32 = 5;
`;

const SRC_LOCAL = `
function f(): void { console.log(z); let z = 1; }
`;

const SRC_RUNS_BEFORE = `
class K { static s: int32 = k; }
(() => { console.log(u); })();
for (const e of later) { console.log(e); }
const k = 1;
let u = 1;
const later = [1, 2];
`;

const SRC_DEFERRED = `
function g(): int32 { return w; }
const h = (): int32 => w;
class K { p: int32 = w; m(): int32 { return w; } }
(() => { const inner = (): int32 => w; })();
test "reads later" { assert w == 1; }
let w = 1;
`;

test "a module let read before its declaration is refused" {
	const text = checkOnly(SRC_TOP_LET).errors.join("\n");
	assert text.contains("Block-scoped variable 'x' used before its declaration"), "a top-level read above its let must be refused: " + text;
}

test "a module const read in a block before its declaration is refused" {
	const text = checkOnly(SRC_TOP_CONST).errors.join("\n");
	assert text.contains("Block-scoped variable 'y' used before its declaration"), "a read in a top-level block above its const must be refused: " + text;
}

test "a local let read before its declaration in the same body is refused" {
	const text = checkOnly(SRC_LOCAL).errors.join("\n");
	assert text.contains("Block-scoped variable 'z' used before its declaration"), "a local read above its let must be refused: " + text;
}

test "a static initializer, an invoked arrow and a loop header run before the declaration and are refused" {
	const text = checkOnly(SRC_RUNS_BEFORE).errors.join("\n");
	assert text.contains("Block-scoped variable 'k' used before its declaration"), "a static initializer read must be refused: " + text;
	assert text.contains("Block-scoped variable 'u' used before its declaration"), "an invoked arrow read must be refused: " + text;
	assert text.contains("Block-scoped variable 'later' used before its declaration"), "a loop header read must be refused: " + text;
}

test "a read inside a function, closure, method, instance initializer or test above the declaration checks" {
	const result = checkOnly(SRC_DEFERRED);
	assert result.errors.length == 0, "deferred reads of a later binding must check: " + result.errors.join("\n");
}

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
	assert text.contains("Block-scoped variable 'x' used before its declaration"), "a self-read initializer reads before its declaration: " + text;
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
