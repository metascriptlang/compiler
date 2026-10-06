import { checkOnly } from "../helpers";

const DECLS = `
struct Box<T> { v: T; }
struct Pair<K, V> { k: K; v: V; }
class C<T> { v: T; constructor(v: T) { this.v = v; } }
`;

const SRC_SCALAR = DECLS + `
function eqZero(a: Box<int32>): boolean { return a == 0; }
function plusOne(a: Box<int32>): int32 { return a + 1; }
function eqText(a: Box<string>): boolean { return a == "s"; }
function pairPlus(a: Pair<int32, string>): int32 { return a + 1; }
function nestedEq(a: Box<Box<int32>>): boolean { return a == 0; }
`;

const SRC_MIXED = DECLS + `
function mixed(a: Box<int32>, b: Box<string>): boolean { return a == b; }
function mixedPair(a: Pair<int32, string>, b: Pair<string, int32>): boolean { return a == b; }
`;

const SRC_VALID = DECLS + `
function same(a: Box<int32>, b: Box<int32>): boolean { return a == b; }
function samePair(a: Pair<int32, string>, b: Pair<int32, string>): boolean { return a == b; }
function member(a: Box<int32> | string, b: Box<int32>): boolean { return a == b; }
function maybe(a: Box<int32> | null, b: Box<int32>): boolean { return a == b || a == null; }
function inner(a: Box<int32>): boolean { return a.v == 0 && a.v + 1 == 2; }
`;

const SRC_OVERLOAD = DECLS + `
function \`==\`(a: Box<int32>, b: int32): boolean { return a.v == b; }
function \`+\`(a: Box<int32>, b: int32): int32 { return a.v + b; }
function eqZero(a: Box<int32>): boolean { return a == 0; }
function plusOne(a: Box<int32>): int32 { return a + 1; }
`;

const SRC_CLASS = DECLS + `
function classZero(a: C<int32>): boolean { return a == 0; }
`;

test "a generic struct instance compared or added to a scalar is a checker error" {
	const text = checkOnly(SRC_SCALAR).errors.join("\n");
	assert text.contains("operator '==' cannot be applied to types 'Box<int32>' and 'int32'"), "Box<int32> == 0 must fail: " + text;
	assert text.contains("operator '+' cannot be applied to types 'Box<int32>' and 'int32'"), "Box<int32> + 1 must fail: " + text;
	assert text.contains("operator '==' cannot be applied to types 'Box<string>' and 'string'"), "Box<string> == \"s\" must fail: " + text;
	assert text.contains("operator '+' cannot be applied to types 'Pair<int32, string>' and 'int32'"), "Pair + 1 must fail: " + text;
	assert text.contains("operator '==' cannot be applied to types 'Box<Box<int32>>' and 'int32'"), "Box<Box<int32>> == 0 must fail: " + text;
}

test "two instances of one generic struct with different arguments do not compare" {
	const text = checkOnly(SRC_MIXED).errors.join("\n");
	assert text.contains("operator '==' cannot be applied to types 'Box<int32>' and 'Box<string>'"), "Box<int32> == Box<string> must fail: " + text;
	assert text.contains("operator '==' cannot be applied to types 'Pair<int32, string>' and 'Pair<string, int32>'"), "swapped Pair arguments must fail: " + text;
}

test "same-argument instances, union members, nullable instances and fields still compare" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "valid instance comparisons must check: " + result.errors.join("\n");
}

test "a declared operator on a generic struct instance still resolves" {
	const result = checkOnly(SRC_OVERLOAD);
	assert result.errors.length == 0, "declared operators must check: " + result.errors.join("\n");
}

test "a generic class instance compared to a scalar stays a checker error" {
	const text = checkOnly(SRC_CLASS).errors.join("\n");
	assert text.contains("operator '==' cannot be applied to types 'C<int32>' and 'int32'"), "C<int32> == 0 must fail: " + text;
}
