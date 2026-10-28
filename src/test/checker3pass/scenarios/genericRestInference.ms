import { checkOnly } from "../helpers";

const DECLS = `
function first<T>(...v: T[]): T { return v[0]; }
function rest<T>(head: T, ...tail: T[]): T[] { return tail; }
`;

function errorsOf(body: string): string {
	return checkOnly(DECLS + body).errors.join("\n");
}

test "a generic rest parameter binds its type parameter from each rest argument and from a spread array" {
	assert errorsOf("const a: int32 = first(1, 2, 3);\nconst xs: string[] = [\"a\"];\nconst b: string = first(...xs);\nconst c: string[] = rest(\"h\", \"t\");\n") == "";
}

test "a generic rest parameter refuses a rest argument of another type than the one bound" {
	const mixed = errorsOf("const a = first(1, \"s\");\n");
	assert mixed.contains("string"), mixed;
	const wrongResult = errorsOf("const a: string = first(1, 2);\n");
	assert wrongResult != "", wrongResult;
}
