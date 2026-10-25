import { checkOnly } from "../helpers";

const SRC_SHARED = `
struct A { kind: "a"; tile: int32; }
struct B { kind: "b"; tile: int32; }
struct C { kind: "c"; other: int32; }
struct D { kind: "d"; tile: int32; }
function two(value: A | B | C): int32 {
	match (value.kind) {
		"a" | "b" => { return value.tile; }
		_ => { return 0; }
	}
}
function three(value: A | B | C | D): int32 {
	return match (value.kind) {
		"a" | "b" | "d" => value.tile,
		_ => 0,
	};
}
`;

const SRC_NOT_SHARED = `
struct A { kind: "a"; tile: int32; }
struct B { kind: "b"; other: int32; }
struct C { kind: "c"; other: int32; }
function selected(value: A | B | C): int32 {
	match (value.kind) {
		"a" | "b" => { return value.tile; }
		_ => { return 0; }
	}
}
`;

test "a match arm with alternatives narrows to the variants they select" {
	const errors = checkOnly(SRC_SHARED).errors;
	assert errors.length == 0, "an arm with two or three alternatives must read a field every selected variant has: " + errors.join("\n");
}

test "a field missing from one selected variant stays refused" {
	const text = checkOnly(SRC_NOT_SHARED).errors.join("\n");
	assert text.contains("field 'tile' exists only on some variants of 'A | B'"), "a field the arm's variants do not share must be refused: " + text;
}
