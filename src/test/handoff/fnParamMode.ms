import { strictErrorCount, hasError, checkSource } from "./helpers";
import { Severity } from "../../checker/context";

const REF = "function bump(ref x: int32): void { x = x + 1; }\nfunction plain(x: int32): void {}\n";

test "a function with a ref parameter does not fit a function type without it" {
	assert hasError(REF + "function visit(f: (x: int32) => void): void {}\nvisit(bump);", "Argument type mismatch in 'visit' arg 0");
}

test "a function without a ref parameter does not fit a function type with it" {
	assert hasError(REF + "function visit(f: (ref x: int32) => void): void {}\nvisit(plain);", "Argument type mismatch in 'visit' arg 0");
}

test "a function with a ref parameter does not fit an out slot" {
	assert hasError(REF + "function visit(f: (out x: int32) => void): void {}\nvisit(bump);", "Argument type mismatch in 'visit' arg 0");
}

test "a function with a ref parameter fits a function type that names ref" {
	assert strictErrorCount(REF + "function visit(f: (ref x: int32) => void): void {}\nvisit(bump);\nconst g: (ref x: int32) => void = bump;") == 0;
}

function varRefusal(src: string, written: string): string {
	const errors: string[] = [];
	for (const err of checkSource(src).errors) {
		if (err.severity == Severity.Error) errors.push(err.message);
	}
	const wanted = "'Var<" + written + ">' was removed: write 'ref name: " + written + "' on the parameter";
	return errors.length > 0 && errors.every((e: string): boolean => e == wanted) ? "" : src + " -> [" + errors.join(" | ") + "]";
}

test "Var<T> is refused on a function parameter, a lambda parameter, a function type and an extension receiver" {
	const problems = [
		varRefusal("function bump(x: Var<int32>): void { x = x + 1; }", "int32"),
		varRefusal("const bump = (x: Var<int32>): void => { x = x + 1; };", "int32"),
		varRefusal("function visit(f: (x: Var<int32>) => void): void {}", "int32"),
		varRefusal("struct P { n: int32; }\nfunction bump(this p: Var<P>): void { p.n = p.n + 1; }", "P"),
	].filter((p: string): boolean => p != "");
	assert problems.length == 0, problems.join("\n");
}

test "ref is accepted on a lambda parameter and an extension receiver" {
	assert strictErrorCount("const bump = (ref x: int32): void => { x = x + 1; };\nlet v: int32 = 1;\nbump(v);") == 0;
	assert strictErrorCount("struct P { n: int32; }\nfunction bump(this ref p: P): void { p.n = p.n + 1; }\nlet q: P = { n: 1 };\nq.bump();") == 0;
}
