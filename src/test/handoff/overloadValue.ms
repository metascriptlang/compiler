// Checker — an overloaded function used as a value picks the overload that matches the function
// type of its slot; no slot type, no fit, a tie, or a set of overload signatures is refused.
// The picked overload's run-time result is pinned by corpus overloadValuePicksBySlot.

import { strictErrorCount, hasError } from "./helpers";

const SET = "function h(x: int32): string { return \"int\"; }\nfunction h(x: string): string { return \"str\"; }\n";

test "an overloaded function with a function-typed slot is accepted" {
	assert strictErrorCount(SET + "const a: (x: string) => string = h;") == 0;
	assert strictErrorCount(SET + "function apply(f: (x: int32) => string): string { return f(1); }\nconsole.log(apply(h));") == 0;
}

test "an overloaded function used as a value without a function type is refused" {
	assert hasError(SET + "const u = h;", "'h' is overloaded, so using it as a value needs a function type");
}

test "an overloaded function no overload of which fits the slot is refused" {
	assert hasError(SET + "const n: (x: boolean) => string = h;", "no overload of 'h' fits '(x: boolean) => string'");
}

test "an overloaded function two overloads of which fit the slot equally is refused" {
	assert hasError("function k(a: int32): string { return \"1\"; }\nfunction k(a: int32, b: int32): string { return \"2\"; }\nconst t: (a: int32, b: int32, c: int32) => string = k;", "'k' is ambiguous here");
}

test "a set of overload signatures used as a value is refused" {
	assert hasError("function s(x: int32): string;\nfunction s(x: string): string;\nfunction s(x: int32 | string): string { return \"impl\"; }\nconst v: (x: int32) => string = s;", "declared by overload signatures");
}
