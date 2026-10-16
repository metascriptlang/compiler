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

const SRC_LAMBDA_UNION = `
function f(g: () => Promise<number> | number): string { return "f"; }
const s = f((): number => 2);
`;

const SRC_EXPLICIT_TYPE_ARG = `
function memo<T>(compute: (prev: T | null) => Promise<T> | T): string { return "memo"; }
function two(prev: number | null): number { return 2; }
const s = memo<number>(two);
`;

const SRC_WRAPPED = `
function take(f: () => number | null): void { }
function run(f: () => void): void { f(); }
function g(): number { return 42; }
take(() => g());
run(() => g());
function widened(): number | null { return 42; }
take(widened);
take((): number | null => 2);
take(() => 2);
`;

function errorsOf(source: string): string {
	return checkOnly(source).errors.join("\n");
}

test "a function into a nullable-return slot names both returns and the lambda" {
	const text = errorsOf(SRC_NULLABLE_SLOT);
	assert text.contains("a function returning 'number' cannot fill a slot returning 'number | null': the result would need a conversion. Pass a lambda (() => g()) or declare g's return type as the union"), "take(g) must explain the wrap: " + text;
}

test "a function into a void-return slot names both returns and the lambda" {
	const text = errorsOf(SRC_VOID_SLOT);
	assert text.contains("a function returning 'number' cannot fill a slot returning 'void': its result would have to be dropped. Pass a lambda (() => k())"), "run(k) must explain the wrap: " + text;
}

test "a function with a parameter among several arguments gets a lambda with that parameter" {
	const text = errorsOf(SRC_TWO_ARGS);
	assert text.contains("a function returning 'int32' cannot fill a slot returning 'void': its result would have to be dropped. Pass a lambda ((a0) => twice(a0))"), "each(3, twice) must explain the wrap: " + text;
}

test "a function assigned to a nullable-return slot names both returns" {
	const text = errorsOf(SRC_ASSIGNED);
	assert text.contains("a function returning 'number' cannot fill a slot returning 'number | null': the result would need a conversion. Pass a lambda (() => g()) or declare g's return type as the union"), "the assignment must explain the wrap: " + text;
}

test "a lambda with a written member return type is told to drop or widen it" {
	const text = errorsOf(SRC_LAMBDA_UNION);
	assert text.contains("a function returning 'number' cannot fill a slot returning 'Promise<number> | number': the result would need a conversion. Leave out the lambda's return type, or declare it as the union"), "the lambda must get both fixes: " + text;
}

test "a function passed under an explicit type argument gets both fixes" {
	const text = errorsOf(SRC_EXPLICIT_TYPE_ARG);
	assert text.contains("a function returning 'number' cannot fill a slot returning 'Promise<number> | number': the result would need a conversion. Pass a lambda ((a0) => two(a0)) or declare two's return type as the union"), "memo<number>(two) must get both fixes: " + text;
}

test "the wrapping lambda and a return type declared as the union check" {
	const result = checkOnly(SRC_WRAPPED);
	assert result.errors.length == 0, "the lambdas must check: " + result.errors.join("\n");
}
