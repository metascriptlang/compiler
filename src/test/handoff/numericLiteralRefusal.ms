import { strictErrorCount, hasError } from "./helpers";

const TYPES = "type Small = { v: 1 | 2; t: uint8 };\nfunction scale(k: 1 | 2): int32 { return k * 10; }\n";

test "number literal types: a literal outside the type is refused naming both" {
	assert hasError("const y: 1 = 2;", "Type '2' is not assignable to type '1'");
	assert hasError("const y: -1 = 1;", "Type '1' is not assignable to type '-1'");
	assert hasError("const y: 1.5 = 1;", "Type '1' is not assignable to type '1.5'");
	assert hasError(TYPES + "scale(3);", "got 3, expected 1 | 2");
	assert hasError(TYPES + "const s: Small = { v: 3, t: 1 };", "Type '3' is not assignable to type '1 | 2'");
}

test "number literal types: a value of a wider type is refused" {
	assert hasError("const k: int32 = 2; const y: 1 = k;", "Type 'int32' is not assignable to type '1'");
	assert hasError("function f(a: 1 | 2) { const b: 2 = a; }", "Type '1 | 2' is not assignable to type '2'");
	assert hasError("const k = 1; const y: 2 = k;", "is not assignable to type '2'");
}

test "number literal types: a literal-typed variable is never stored a computed number" {
	assert hasError("let n: 1 | 2 = 1; n += 1;", "would store a 'int32' in '1 | 2'");
	assert hasError("let n: 1 | 2 = 1; n++;", "increment/decrement needs a numeric operand");
	assert hasError(TYPES + "const s: Small = { v: 1, t: 1 }; s.v -= 1;", "would store a 'int32' in '1 | 2'");
	assert strictErrorCount("let m: int32 = 1; m += 1;") == 0;
}

test "number literal types: integer and fractional literals in one union are each held" {
	assert strictErrorCount("const a: 1 | 1.5 = 1; const b: 1 | 1.5 = 1.5; const c: 1.0 | 1.5 = 1.5;") == 0;
	assert hasError("const a: 1 | 1.5 = 2;", "Type '2' is not assignable to type '1 | 1.5'");
}

test "number literal types: a value with no run-time type is refused" {
	assert hasError("const a: 0x10 = 16;", "is not a numeric literal type");
	assert hasError("const a: 99999999999999999999 = 1;", "is not a numeric literal type");
}

test "number literal types: the accepted forms raise nothing" {
	assert strictErrorCount("const x: 1 = 1; const z: -1 | 0 = -1; const w: 1 | 2 | string = \"s\";") == 0;
	assert strictErrorCount(TYPES + "const s: Small = { v: 2, t: 1 }; scale(s.v);") == 0;
	assert strictErrorCount("function g(v: 1 | 2 | string): boolean { return v === 1; }") == 0;
}
