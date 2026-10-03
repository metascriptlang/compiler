
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
