import { checkOnly } from "../helpers";

const SRC_RETURN = `
function f(b: boolean): int32 | void {
	if (b) { return 1; }
}
`;

const SRC_PARAMETER = `
function g(x: string | void): void { }
`;

const SRC_FIELD = `
interface Box {
	v: void | boolean;
}
`;

const SRC_GENERIC_ARG = `
class Cell<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
const c: Cell<int32 | void> = new Cell<int32>(1);
`;

const SRC_PROMISE = `
async function p(): Promise<int32 | void> { return 1; }
`;

const SRC_VALID = `
function f(b: boolean): int32 | null {
	if (b) { return 1; }
	return null;
}
function g(x: string | null): void { }
async function p(): Promise<void> { }
const run: () => void = (): void => { };
`;

function errorsOf(source: string): string {
	return checkOnly(source).errors.join("\n");
}

test "a return type with void in a union is refused with T | null" {
	const text = errorsOf(SRC_RETURN);
	assert text.contains("'int32 | void' puts void in a union, and void is no value — write 'int32 | null'"), "int32 | void must fail the checker: " + text;
}

test "a parameter with void in a union is refused" {
	const text = errorsOf(SRC_PARAMETER);
	assert text.contains("'string | void' puts void in a union, and void is no value — write 'string | null'"), "string | void must fail the checker: " + text;
}

test "a field with void first in a union is refused" {
	const text = errorsOf(SRC_FIELD);
	assert text.contains("'void | boolean' puts void in a union, and void is no value — write 'null | boolean'"), "void | boolean must fail the checker: " + text;
}

test "a type argument with void in a union is refused" {
	assert errorsOf(SRC_GENERIC_ARG).contains("'int32 | void' puts void in a union"), "Cell<int32 | void> must fail the checker";
	assert errorsOf(SRC_PROMISE).contains("'int32 | void' puts void in a union"), "Promise<int32 | void> must fail the checker";
}

test "T | null, a void return and Promise<void> still check" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "void outside a union must check: " + result.errors.join("\n");
}
