import { checkOnly } from "../helpers";

const SRC_NULLABLE_SLOT = `
function take(f: () => number | null): void { }
function g(): number { return 42; }
take(g);
`;

const SRC_VOID_SLOT = `
function run(f: () => void): void { f(); }
function k(): number { return 1; }
run(k);
`;

const SRC_TWO_ARGS = `
function each(n: int32, f: (i: int32) => void): void { f(n); }
function twice(i: int32): int32 { return i * 2; }
each(3, twice);
`;

const SRC_ASSIGNED = `
function g(): number { return 42; }
const h: () => number | null = g;
`;

const SRC_WRAPPED = `
function take(f: () => number | null): void { }
function run(f: () => void): void { f(); }
function g(): number { return 42; }
take(() => g());
run(() => g());
`;

function errorsOf(source: string): string {
	return checkOnly(source).errors.join("\n");
}

test "a function into a nullable-return slot names both returns and the lambda" {
	const text = errorsOf(SRC_NULLABLE_SLOT);
	assert text.contains("a function returning number cannot stand in for one returning number | null, because the two results are held differently; wrap it in a lambda: take(() => g())"), "take(g) must explain the wrap: " + text;
}

test "a function into a void-return slot names both returns and the lambda" {
	const text = errorsOf(SRC_VOID_SLOT);
	assert text.contains("a function returning number cannot stand in for one returning void, because the two results are held differently; wrap it in a lambda: run(() => k())"), "run(k) must explain the wrap: " + text;
}

test "a function with a parameter among several arguments gets a lambda with that parameter" {
	const text = errorsOf(SRC_TWO_ARGS);
	assert text.contains("a function returning int32 cannot stand in for one returning void, because the two results are held differently; wrap it in a lambda: pass (a0) => twice(a0) as arg 1"), "each(3, twice) must explain the wrap: " + text;
}

test "a function assigned to a nullable-return slot names both returns" {
	const text = errorsOf(SRC_ASSIGNED);
	assert text.contains("a function returning number cannot stand in for one returning number | null, because the two results are held differently; wrap it in a lambda: () => g()"), "the assignment must explain the wrap: " + text;
}

test "the wrapping lambdas check" {
	const result = checkOnly(SRC_WRAPPED);
	assert result.errors.length == 0, "the lambdas must check: " + result.errors.join("\n");
}
