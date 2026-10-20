import { checkOnly } from "../helpers";

const SRC_NARROWED = `
type Style = "solid" | "wavy" | "dotted";
function draw(line: "solid" | "wavy" | null): string { return line === null ? "none" : line; }
function returned(own: Style | null): string {
	if (own === "dotted") return "dots";
	return draw(own);
}
function elsed(x: "a" | "b" | "c" | null): "a" | "b" | null {
	if (x !== "c") { return x; } else { return null; }
}
function either(x: "a" | "b" | "c" | null): "c" | null {
	if (x === "a" || x === "b") return null;
	return x;
}
function matched(x: "a" | "b" | "c" | null): "c" {
	if (x === "c") return x;
	return "c";
}
function numbered(x: 1 | 2 | 3 | null): 1 | 2 | null {
	if (x === 3) return null;
	return x;
}
function numberElsed(x: 1 | 2 | 3 | null): 3 {
	if (x !== 3) { return 3; } else { return x; }
}
`;

const SRC_KEPT = `
function kept(x: "a" | "b" | "c" | null): "a" | "b" {
	if (x === "c") return "a";
	return x;
}
function wrongBranch(x: "a" | "b" | "c" | null): "a" | "b" | null {
	if (x === "c") return x;
	return null;
}
`;

const SRC_NOT_EQUALITY = `
function nullableEquals(a: string | null, b: string | null): boolean { return a !== b; }
function g(x: "a" | "b" | "c" | null): "a" | "b" | null {
	if (nullableEquals(x, "c")) return null;
	return x;
}
`;

test "equality with a literal narrows a nullable literal union" {
	const errors = checkOnly(SRC_NARROWED).errors;
	assert errors.length == 0, "=== and !== against a literal must narrow a nullable literal union: " + errors.join("\n");
}

test "the false branch keeps null and the true branch keeps only the literal" {
	const text = checkOnly(SRC_KEPT).errors.join("\n");
	assert text.contains("Type '\"a\" | \"b\" | null' is not assignable to type '\"a\" | \"b\"'"), "the false branch of === must keep null: " + text;
	assert text.contains("Type '\"c\"' is not assignable to type '\"a\" | \"b\" | null'"), "the true branch of === must hold only the literal: " + text;
}

test "a function named like the equality routine does not narrow" {
	const text = checkOnly(SRC_NOT_EQUALITY).errors.join("\n");
	assert text.contains("is not assignable to type '\"a\" | \"b\" | null'"), "a user call must not narrow as equality: " + text;
}
