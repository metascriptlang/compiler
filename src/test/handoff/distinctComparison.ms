import { checkProjectDiagnostics, MapEntry } from "../helpers";

const head = "type UserId = distinct int32;\ntype OrderId = distinct int32;\ntype Tag = distinct string;\n"
	+ "struct P { x: int32; }\ntype Q = distinct P;\nenum Color { Red, Green }\ntype Hue = distinct Color;\n"
	+ "type Tagged<S> = distinct int32;\ntype Fn = distinct (() => int32);\n"
	+ "type Id = int32 & { __brand: \"Id\" };\n";

function diagnostics(body: string): string[] {
	const entries: MapEntry[] = [{ entryPath: "src/main.ms", entrySource: head + body }];
	return checkProjectDiagnostics(entries, "src/main.ms");
}

function count(body: string, text: string): int32 {
	let n: int32 = 0;
	for (const m of diagnostics(body)) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

function refused(body: string): int32 {
	let n: int32 = 0;
	for (const m of diagnostics(body)) {
		if (m.indexOf("cannot") >= 0 || m.indexOf("delegate") >= 0 || m.indexOf("distinct type") >= 0) n += 1;
	}
	return n;
}

function compared(t: string, op: string): string {
	return "function f(a: " + t + ", b: " + t + "): boolean { return a " + op + " b; }\n";
}

const inherit = "a distinct type does not inherit the comparisons of its base";
const mixed = "a distinct type compares only with itself";

test "distinctComparison: a distinct has no comparison of its base until one is delegated" {
	for (const op of ["==", "!=", "===", "!==", "<", "<=", ">", ">="]) {
		assert count(compared("UserId", op), inherit) == 1, op;
		assert count(compared("Tag", op), inherit) == 1, op;
		assert count(compared("Tagged<P>", op), inherit) == 1, op;
	}
	assert count(compared("Q", "=="), inherit) == 1;
	assert count(compared("Hue", "=="), inherit) == 1;
	assert count(compared("Fn", "=="), inherit) == 1;
}

test "distinctComparison: the refusal names the delegate line to write" {
	assert count(compared("UserId", "<"), "add `@delegate function `<`(this a: UserId, b: UserId): boolean;` to compare as 'int32'") == 1;
	assert count(compared("UserId", ">"), "add `@delegate function `<`(this a: UserId, b: UserId): boolean;` to compare as 'int32' (`>` follows from `<`)") == 1;
	assert count(compared("Tag", "!="), "add `@delegate function `==`(this a: Tag, b: Tag): boolean;` to compare as 'string' (`!=` follows from `==`)") == 1;
}

test "distinctComparison: a distinct compared with its base, a literal or another distinct is refused" {
	const delegated = "@delegate function `==`(this a: UserId, b: UserId): boolean;\n@delegate function `<`(this a: UserId, b: UserId): boolean;\n";
	assert count(delegated + "function f(a: UserId, b: OrderId): boolean { return a == b; }\n", mixed) == 1;
	assert count(delegated + "function f(a: UserId, b: int32): boolean { return a == b; }\n", mixed) == 1;
	assert count(delegated + "function f(a: UserId): boolean { return a == 1; }\n", mixed) == 1;
	assert count(delegated + "function f(a: UserId, b: OrderId): boolean { return a < b; }\n", mixed) == 1;
	assert count(delegated + "function f(a: UserId): boolean { return a == (1 as UserId); }\n", mixed) == 0;
}

test "distinctComparison: delegating ==, < and <= gives every comparison" {
	const delegated = "@delegate function `==`(this a: UserId, b: UserId): boolean;\n@delegate function `<`(this a: UserId, b: UserId): boolean;\n"
		+ "@delegate function `<=`(this a: UserId, b: UserId): boolean;\n";
	for (const op of ["==", "!=", "===", "!==", "<", "<=", ">", ">="]) {
		assert refused(delegated + compared("UserId", op)) == 0, op;
	}
	const generic = "@delegate function `==`<S>(this a: Tagged<S>, b: Tagged<S>): boolean;\n";
	assert refused(generic + compared("Tagged<P>", "!=")) == 0;
	assert refused("@delegate function `==`(this a: Hue, b: Hue): boolean;\n" + compared("Hue", "!=")) == 0;
}

test "distinctComparison: a delegate takes only a comparison the base has" {
	assert count("@delegate function `!=`(this a: UserId, b: UserId): boolean;\n", "@delegate '!=': no !=(int32, int32) to delegate to") == 1;
	assert count("@delegate function `<`(this a: Fn, b: Fn): boolean;\n", "@delegate '<': no <(") == 1;
	assert count("@delegate function `<=`(this a: UserId, b: UserId): int32;\n", "@delegate '<=' returns 'int32' but <=(int32, int32) returns 'boolean'") == 1;
}

test "distinctComparison: a brand compares as its base" {
	for (const op of ["==", "!=", "<", ">="]) {
		assert refused(compared("Id", op)) == 0, op;
	}
	assert refused("function f(a: Id, b: int32): boolean { return a == b && a < 3; }\n") == 0;
}
