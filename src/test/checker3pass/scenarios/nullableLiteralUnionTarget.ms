import { checkOnly } from "../helpers";

const SRC_FROM_BASE = `
function st(): string | null { return "zz"; }
const t: "a" | "b" | null = st();
`;

const SRC_FROM_WIDER = `
function abc(): "a" | "b" | "c" | null { return "c"; }
const t: "a" | "b" | null = abc();
`;

test "a nullable string does not fit a nullable literal union" {
	const text = checkOnly(SRC_FROM_BASE).errors.join("\n");
	assert text.contains("'string | null' is not assignable to type '\"a\" | \"b\" | null'"), "string | null into \"a\" | \"b\" | null must fail the checker: " + text;
}

test "a wider nullable literal union does not fit a narrower one" {
	const text = checkOnly(SRC_FROM_WIDER).errors.join("\n");
	assert text.contains("is not assignable to type '\"a\" | \"b\" | null'"), "\"a\" | \"b\" | \"c\" | null into \"a\" | \"b\" | null must fail the checker: " + text;
}
