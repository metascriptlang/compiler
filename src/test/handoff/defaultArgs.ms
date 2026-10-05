// Test: extension methods with default parameters fill missing args at call site
// When indexOf(this s: string, sub: string, start: number = 0) is called as s.indexOf("x"),
// the codegen must emit msStringIndexOf(s, "x", 0) — not msStringIndexOf(s, "x").

import { compileToC } from "../helpers";
import { hasError, strictErrorCount } from "./helpers";

test "indexOf with missing start arg fills default 0" {
	const src = `
export function find(s: string): number {
	return s.indexOf("*");
}
`;
	const r = compileToC(src);
	assert r.ok;
	// Must have 3 args: msStringIndexOf(s, "*", 0)
	assert r.value.contains(", 0)");
}

test "indexOf with explicit start arg passes through" {
	const src = `
export function find(s: string): number {
	return s.indexOf("*", 5);
}
`;
	const r = compileToC(src);
	assert r.ok;
}

test "a default value is checked where it is declared, seeing only the parameters before it" {
	assert hasError("function bad(a: int32, b: string = a): string { return b; }", "'int32' is not assignable to type 'string'");
	assert hasError("function later(a: string = b, b: string = \"x\"): string { return a; }", "Undefined variable 'b'");
	assert hasError("function self(a: string = a): string { return a; }", "Undefined variable 'a'");
	assert strictErrorCount("function label(name: string, shown: string = name): string { return shown; }") == 0;
}

test "a default value that reads an earlier parameter takes the argument at the call" {
	const pre = "function label(name: string, shown: string = name): string { return name + shown; }\n"
		+ "function next(): string { return \"n\"; }\n";
	assert strictErrorCount(pre + "const a = label(\"a\"); const b = label(next()); const c = true ? label(next()) : \"\"; const f = (): string => label(next());") == 0;
	const c = compileToC(pre + "export function run(): string { return label(next()); }");
	assert c.ok, c.ok ? "" : c.error;
}

test "an argument a default value reads is bound once only where a statement can hold it" {
	const pre = "function label(name: string, shown: string = name): string { return name + shown; }\n"
		+ "function next(): string { return \"n\"; }\n";
	assert hasError(pre + "class Holder { s: string = label(next()); }", "a field initializer has no statement to bind it in");
	assert strictErrorCount(pre + "const seed = \"s\"; class Holder { s: string = label(seed); }") == 0;
	assert hasError("function bump(ref a: int32, b: int32 = a): int32 { a += b; return a; }\nconst xs: int32[] = [1];\nbump(xs[0]);", "a default value reads the ref parameter 'a', so its argument must be a variable");
}
