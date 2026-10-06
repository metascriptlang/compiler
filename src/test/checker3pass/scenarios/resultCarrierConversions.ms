
import { checkOnly } from "../helpers";

const SRC_CAST = `
function make(): Result<string, string> {
	return Result.ok("x");
}
const code = make() as int32;
if (code > 0) { code; }
`;

const SRC_CAST_INT = `
function makeInt(): Result<int32, string> {
	return Result.ok(3);
}
const code = makeInt() as int32;
if (code > 0) { code; }
`;

const SRC_COMPARE = `
function make(): Result<string, string> {
	return Result.ok("x");
}
const r = make();
if (r !== 0) { r; }
`;

const SRC_COMPARE_EQ = `
function make(): Result<int32, string> {
	return Result.ok(3);
}
if (make() == 0) { make; }
`;

const SRC_VALID = `
function make(): Result<string, string> {
	return Result.ok("x");
}
const r = make();
if (!r.ok) { r; }
if (r.ok) { r.value; }
`;

test "payload carrier as primitive is a checker error naming both types" {
	const result = checkOnly(SRC_CAST);
	assert result.errors.length > 0, "make() as int32 must fail the checker";
	const text = result.errors.join("\n");
	assert text.contains("int32"), "error must name the target type: " + text;
	assert text.contains("Result"), "error must name the carrier type: " + text;
}

test "payload carrier of int32 as int32 is still refused" {
	const result = checkOnly(SRC_CAST_INT);
	assert result.errors.length > 0, "Result<int32, string> as int32 must fail the checker";
	assert result.errors.join("\n").contains("Result"), "error must name the carrier type";
}

test "payload carrier compared with a number is a checker error on both operators" {
	const strictNe = checkOnly(SRC_COMPARE);
	assert strictNe.errors.length > 0, "r !== 0 must fail the checker";
	const looseEq = checkOnly(SRC_COMPARE_EQ);
	assert looseEq.errors.length > 0, "make() == 0 must fail the checker";
	const text = looseEq.errors.join("\n");
	assert text.contains("Result"), "comparison error must name the carrier type: " + text;
}

test "valid Result member access still checks clean" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "r.ok / r.value must stay clean: " + result.errors.join("\n");
}

const SRC_NULLABLE_PRIMITIVE_UNION_CAST = `
function wire(): number | string | null { return "a"; }
const s = wire() as string;
const n = wire() as number | null;
`;

const SRC_NULLABLE_CARRIER_CAST = `
function make(): Result<int32, string> | null { return Result.ok(3); }
const code = make() as int32;
`;

const SRC_NULLABLE_GENERIC_STRUCT_EQ = `
struct Box<T> { v: T; }
function same(a: Box<int32> | null, b: Box<int32> | null): boolean { return a == b; }
function none(a: Box<int32> | null): boolean { return a == null; }
`;

const SRC_NULLABLE_STRUCT_EQ_NUMBER = `
struct P { v: int32; }
function bad(a: P | null): boolean { return a == 0; }
`;

test "a nullable union of primitives narrows to its member with as" {
	const result = checkOnly(SRC_NULLABLE_PRIMITIVE_UNION_CAST);
	assert result.errors.length == 0, "number | string | null as string must stay clean: " + result.errors.join("\n");
}

test "a nullable payload carrier as primitive is still refused" {
	const result = checkOnly(SRC_NULLABLE_CARRIER_CAST);
	assert result.errors.length > 0, "Result<int32, string> | null as int32 must fail the checker";
	assert result.errors.join("\n").contains("Result"), "error must name the carrier type";
}

test "nullable generic struct instances compare with each other and with null" {
	const result = checkOnly(SRC_NULLABLE_GENERIC_STRUCT_EQ);
	assert result.errors.length == 0, "Box<int32> | null == Box<int32> | null must stay clean: " + result.errors.join("\n");
}

test "a nullable struct compared with a number is refused" {
	const result = checkOnly(SRC_NULLABLE_STRUCT_EQ_NUMBER);
	assert result.errors.length > 0, "P | null == 0 must fail the checker";
}
