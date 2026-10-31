// Checker: a number union converts into a numeric slot member by member, and refuses where one member would lose data

import { strictErrorCount, hasError } from "./helpers";

const NUM = "type Num = int32 | float64;\n";

test "an int32 or float64 union fits a float64 local, return, argument and field" {
	assert strictErrorCount(NUM + "function f(d: Num): float64 { const x: float64 = d; return x; }") == 0;
	assert strictErrorCount(NUM + "function f(d: Num): float64 { return d; }") == 0;
	assert strictErrorCount(NUM + "function t(v: float64): float64 { return v; }\nfunction f(d: Num): float64 { return t(d); }") == 0;
	assert strictErrorCount(NUM + "class B { n: float64 = 0; }\nfunction f(d: Num, b: B): void { b.n = d; }") == 0;
}

test "a union with a float64 member is refused into int32 and float32" {
	assert hasError(NUM + "function f(d: Num): int32 { const x: int32 = d; return x; }", "Type 'float64 | int32' is not assignable to type 'int32'");
	assert hasError(NUM + "function f(d: Num): float32 { const x: float32 = d; return x; }", "not assignable to type 'float32'");
}

test "an int32 or int64 union is refused into float64 where int64 loses bits" {
	assert hasError("function f(d: int32 | int64): float64 { const x: float64 = d; return x; }", "not assignable to type 'float64'");
}
