import { hasError, strictErrorCount } from "./helpers";

const DECL = "extern function name(s: cstring): cstring from \"name\";\n";

test "cstringIntoString: a cstring is refused as a string by const, argument, return and concatenation, naming the copy" {
	const refused = [
		{ name: "a const with a string type", source: DECL + "const s: string = name(\"a\");" },
		{ name: "a string argument", source: DECL + "function take(s: string): void {}\ntake(name(\"a\"));" },
		{ name: "a string return", source: DECL + "function f(): string { return name(\"a\"); }" },
		{ name: "a concatenation", source: DECL + "const s = name(\"a\") + \"!\";" },
		{ name: "a concatenation on the right", source: DECL + "const s = \"!\" + name(\"a\");" },
	];
	for (const row of refused) {
		assert hasError(row.source, "write 'as string'"), row.name;
	}
}

test "cstringIntoString: as string copies at the cast and string still converts to cstring implicitly" {
	const accepted = [
		{ name: "a cast const", source: DECL + "const s = name(\"a\") as string;" },
		{ name: "a cast return", source: DECL + "function f(): string { return name(\"a\") as string; }" },
		{ name: "a string argument to a cstring parameter", source: DECL + "function f(s: string): cstring { return name(s); }" },
	];
	for (const row of accepted) {
		assert strictErrorCount(row.source) == 0, row.name;
	}
}
