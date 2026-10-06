import { checkOnly } from "../helpers";

const SRC_INT32 = `
function box<T>(v: T): T[] { return [v]; }
const a = box(0);
const f: number[] = a;
`;

const SRC_WIDE = `
function box<T>(v: T): T[] { return [v]; }
const b: int64[] = box(3000000000);
const c: int32[] = box(0);
const d: number[] = box<number>(0);
const e: number[] = box(0.0);
`;

test "an integer literal alone binds a type parameter to int32" {
	const text = checkOnly(SRC_INT32).errors.join("\n");
	assert text.contains("'int32[]' is not assignable to type 'number[]'"), "box(0) must stay int32[]: " + text;
}

test "the literal's width and an explicit type argument decide the binding" {
	const errors = checkOnly(SRC_WIDE).errors;
	assert errors.length == 0, "int64 past int32, number by type argument or float literal: " + errors.join("\n");
}
